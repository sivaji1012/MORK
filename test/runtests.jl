using Test
using MORK

@testset "MORK — Phase 0 skeleton" begin
    # Phase 0 landing criteria (per docs/architecture/MORK_PACKAGE_PLAN.md):
    # - `using MORK` succeeds
    # - test suite runs
    # - zero PRIMUS_* imports reachable from MORK
    @test MORK.version() == v"0.1.0"
    @test isdefined(MORK, :version)
end
