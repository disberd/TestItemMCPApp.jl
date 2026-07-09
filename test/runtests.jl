using TestItemRunner

# FakeTestPkg under test/fixtures/ is itself scanned for @testitem blocks by the
# walk that @run_package_tests performs over the whole package tree. Its test
# items (including deliberately failing ones) are fixtures for the MCP tools
# under test, not part of this package's own test suite, so exclude them here.
@run_package_tests filter = ti -> !occursin(joinpath("test", "fixtures"), ti.filename)
