@testitem "two copies of one package keep separate test environments" setup=[MCPTestHelpers] begin
    using Test
    import TestItemMCPApp
    import JuliaWorkspaces

    # Two checkouts of the same package in one workspace. `item_package_info` and
    # `env_id_for_item` are keyed by `(testitem_id, package_uri)`, so each copy keeps
    # its own entry and its test items run against its own package environment.
    #
    # JuliaWorkspaces 8 qualifies a test item id by absolute file URI, so the two
    # copies get different ids and cannot collide here. The id format in newer
    # JuliaWorkspaces versions is package scoped, and then the ids do collide. This
    # test pins the routing invariant that holds under both formats.
    workdir = mktempdir()
    copy_a = joinpath(workdir, "a", "FakeTestPkg")
    copy_b = joinpath(workdir, "b", "FakeTestPkg")
    mkpath(dirname(copy_a))
    mkpath(dirname(copy_b))
    cp(FIXTURE_PKG_PATH, copy_a)
    cp(FIXTURE_PKG_PATH, copy_b)

    session = TestItemMCPApp.SessionState("two-copies")
    session.workspace = JuliaWorkspaces.workspace_from_folders([copy_a, copy_b])

    items, _, item_package_info = TestItemMCPApp.resolve_testitems(session)

    # Both copies contribute their items; neither replaces the other.
    @test !isempty(items)
    @test length(item_package_info) == length(items)
    @test all(k -> k isa Tuple{String,String}, keys(item_package_info))

    package_uris = unique(last.(collect(keys(item_package_info))))
    @test length(package_uris) == 2

    test_envs, env_id_for_item, _, _, _ =
        TestItemMCPApp.build_test_environments(Dict{String,Any}(), item_package_info)

    # One environment per copy.
    @test length(test_envs) == 2
    @test length(unique(string(e.package_uri) for e in test_envs)) == 2

    # Every item points at the environment of the copy it came from.
    for item in items
        env_id = env_id_for_item[(item.id, item.package_uri)]
        env = only(filter(e -> e.id == env_id, test_envs))
        @test string(env.package_uri) == item.package_uri
    end

    rm(workdir; recursive=true, force=true)
end
