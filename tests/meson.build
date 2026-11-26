# Tests for the parts of Timeshift that don't need root or a real system.
# Run them with: meson test -C build

test_dependencies = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gee-0.8'),
]

# the code under test is copied into the build directory, valac does not handle
# sources from another directory well
package_transaction_source = configure_file(
  input: '../src/Core/PackageTransaction.vala',
  output: 'PackageTransaction.vala',
  copy: true,
)

package_transaction_test = executable(
  'package-transaction-test',
  files('PackageTransactionTest.vala'),
  package_transaction_source,
  dependencies: test_dependencies,
)

test('package-transaction', package_transaction_test)
