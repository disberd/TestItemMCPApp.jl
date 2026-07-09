@testitem "pass_test" begin
    using Test
    @test 1 + 1 == 2
end

@testitem "fail_test" begin
    using Test
    @test 1 == 2
end

@testitem "env_var_test" begin
    using Test
    @test ENV["MY_TEST_VAR"] == "hello"
end

@testitem "slow_test" begin
    using Test
    sleep(2)
    @test true
end

@testitem "logging_test" begin
    using Test
    @info "this is a log message"
    println("this is stdout")
    @test true
end
