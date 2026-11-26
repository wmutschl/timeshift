/*
 * BtrfsSendTask.vala
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */

using TeeJee.Logging;
using TeeJee.ProcessHelper;

/*
 * Runs 'btrfs send' and pipes its output into a receiving command, e.g.
 * 'btrfs receive <dir>' or 'ssh <host> btrfs receive <dir>', without a shell.
 * The stream is copied by this process so that the transferred bytes can be
 * counted and the transfer can be cancelled.
 */
public class BtrfsSendTask : GLib.Object {

	public int64 bytes_transferred = 0;
	public string send_error = "";
	public string receive_error = "";
	public string error_message = "";

	private Cancellable cancellable = new Cancellable();
	private Subprocess? sender = null;
	private Subprocess? receiver = null;

	// called from the copying loop, about once per second
	public signal void progress(int64 bytes, double seconds);

	/*
	 * source: read-only subvolume to send
	 * parent: read-only subvolume to send the difference against (incremental
	 *         send), or "" for a full send
	 * receive_argv: the receiving command, e.g. { "btrfs", "receive", "/mnt/target/dir" }
	 * Returns true if both commands succeeded.
	 */
	public bool run(string source, string parent, string[] receive_argv, bool compressed_data = false){

		string[] send_argv = { "btrfs", "send" };
		if (compressed_data){
			send_argv += "--compressed-data";
		}
		if (parent.length > 0){
			send_argv += "-p";
			send_argv += parent;
		}
		send_argv += source;

		log_debug(argv_to_string(send_argv) + " | " + argv_to_string(receive_argv));

		try{
			sender = new Subprocess.newv(send_argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
			receiver = new Subprocess.newv(receive_argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDOUT_SILENCE);
		}
		catch (Error e){
			error_message = e.message;
			if (sender != null){
				sender.force_exit();
			}
			return false;
		}

		// collect stderr in background threads, a full pipe would block the commands
		var send_err_thread = new Thread<string>("send-stderr", () => { return read_all(sender.get_stderr_pipe()); });
		var recv_err_thread = new Thread<string>("receive-stderr", () => { return read_all(receiver.get_stderr_pipe()); });

		bool copied = copy_stream(sender.get_stdout_pipe(), receiver.get_stdin_pipe());

		if (!copied){
			// receiver died or the transfer was cancelled
			sender.force_exit();
			receiver.force_exit();
		}

		try{
			sender.wait();
			receiver.wait();
		}
		catch (Error e){
			log_debug(e.message);
		}

		send_error = send_err_thread.join().strip();
		receive_error = recv_err_thread.join().strip();

		bool ok = copied && sender.get_if_exited() && (sender.get_exit_status() == 0)
			&& receiver.get_if_exited() && (receiver.get_exit_status() == 0);

		if (!ok && (error_message.length == 0)){
			if (cancellable.is_cancelled()){
				error_message = _("Cancelled");
			}
			else if (receive_error.length > 0){
				error_message = receive_error;
			}
			else if (send_error.length > 0){
				error_message = send_error;
			}
			else{
				error_message = _("btrfs send or receive failed");
			}
		}

		return ok;
	}

	public void cancel(){
		cancellable.cancel();
	}

	private bool copy_stream(InputStream input, OutputStream output){

		uint8[] buffer = new uint8[1024 * 1024];
		var timer = new Timer();
		double last_report = 0;

		try{
			while (true){
				ssize_t n = input.read(buffer, cancellable);
				if (n <= 0){
					break;
				}

				size_t written;
				output.write_all(buffer[0:n], out written, cancellable);
				bytes_transferred += n;

				double now = timer.elapsed();
				if (now - last_report >= 1.0){
					progress(bytes_transferred, now);
					last_report = now;
				}
			}

			output.close();
			progress(bytes_transferred, timer.elapsed());
			return true;
		}
		catch (Error e){
			if (!cancellable.is_cancelled()){
				error_message = e.message;
			}
			try { output.close(); } catch (Error e2) { }
			return false;
		}
	}

	private static string read_all(InputStream? stream){

		if (stream == null){
			return "";
		}

		var sb = new StringBuilder();
		uint8[] buffer = new uint8[4096];

		try{
			ssize_t n;
			while ((n = stream.read(buffer)) > 0){
				sb.append_len((string) buffer, n);
			}
		}
		catch (Error e){
			// ignore
		}

		return sb.str;
	}
}

/*
 * Properties of a subvolume as reported by 'btrfs subvolume show'.
 */
public class BtrfsSubvolumeInfo : GLib.Object {

	public string path = "";
	public string uuid = "";
	public string parent_uuid = "";
	public string received_uuid = "";
	public bool readonly = false;
	public int64 generation = -1;

	public static BtrfsSubvolumeInfo? query(string path, string[]? command_prefix = null){

		string[] argv = {};
		if (command_prefix != null){
			foreach(string arg in command_prefix){
				argv += arg;
			}
		}
		argv += "btrfs";
		argv += "subvolume";
		argv += "show";
		argv += path;

		string std_out, std_err;
		if (exec_argv_sync(argv, out std_out, out std_err) != 0){
			return null;
		}

		var info = parse(std_out);
		info.path = path;
		return info;
	}

	public static BtrfsSubvolumeInfo parse(string output){

		var info = new BtrfsSubvolumeInfo();

		foreach(string line in output.split("\n")){

			int pos = line.index_of(":");
			if (pos < 0){
				continue;
			}

			string key = line.substring(0, pos).strip();
			string value = line.substring(pos + 1).strip();

			if (value == "-"){
				value = "";
			}

			switch (key){
				case "UUID":
					info.uuid = value;
					break;
				case "Parent UUID":
					info.parent_uuid = value;
					break;
				case "Received UUID":
					info.received_uuid = value;
					break;
				case "Flags":
					info.readonly = value.contains("readonly");
					break;
				case "Generation":
					info.generation = int64.parse(value);
					break;
			}
		}

		return info;
	}
}
