# metta_thread_basic.jl — ports metta_thread_basic_works_without_substitution
# from server/tests/exec_mm2.rs
#
# Multi-step rewrite: val(x,y) → out(val x y) + out(val y x) via def/exec chain.
# Expected: 8 output atoms for 4 input (val ...) pairs.
using MORK, HTTP, JSON3, Test

const PORT = 9908
const BASE = "http://127.0.0.1:$PORT"

ss  = ServerSpace()
srv = serve_background!(ss, PORT)
sleep(2)

function wait_eq(url, expected, timeout=15.0)
    deadline = time() + timeout
    while time() < deadline
        try
            j = JSON3.read(HTTP.get(url; readtimeout=3).body)
            String(j[:status]) == expected && return true
        catch; end
        sleep(0.2)
    end
    false
end

function wait_ne(url, expected, timeout=15.0)
    deadline = time() + timeout
    while time() < deadline
        try
            j = JSON3.read(HTTP.get(url; readtimeout=3).body)
            s = String(j[:status])
            s != expected && return s
        catch; end
        sleep(0.2)
    end
    "timeout"
end

# URL-encode helpers
enc(s) = HTTP.URIs.escapeuri(s)

@testset "metta_thread — basic works (ports exec_mm2.rs)" begin

    # ── Step 1: Upload input vals → (metta_thread_basic in) namespace ────
    r1 = HTTP.post(
        "$BASE/upload/$(enc("\$v"))/$(enc("((metta_thread_basic in) \$v)"))",
        [], "(val a b)\n(val c d)\n(val e f)\n(val g h)\n")
    @test r1.status == 200
    @test wait_eq("$BASE/status/$(enc("((metta_thread_basic in) \$v)"))", "pathClear")

    # ── Step 2: Upload def expressions (step 0 and step 1) ───────────────
    defs = """
(def metta_thread_basic 0
     (, ((metta_thread_basic in) (val \$x \$y))
        (def metta_thread_basic 1 \$p \$t)
     )
     (, (exec ((metta_thread_basic state) cleanup) (, (val \$y \$x)) (,))
        (exec (metta_thread_basic asap) \$p \$t)
        ((metta_thread_basic out) (val \$x \$y))
     )
)
(def metta_thread_basic 1
     (, (exec ((metta_thread_basic state) \$p) (, (val \$u \$v)) (,)))
     (, ((metta_thread_basic out) (val \$u \$v)))
)
"""
    r2 = HTTP.post(
        "$BASE/upload/$(enc("(def \$loc \$step \$p \$t)"))/$(enc("(def \$loc \$step \$p \$t)"))",
        [], defs)
    @test r2.status == 200
    @test wait_eq("$BASE/status/$(enc("(def metta_thread_basic \$step \$p \$t)"))", "pathClear")

    # ── Step 3: Upload initial exec rule ─────────────────────────────────
    init_exec = """
(exec (metta_thread_basic asap) (, (def metta_thread_basic 0 \$p \$t)) (, (exec (metta_thread_basic asap) \$p \$t)))
"""
    r3 = HTTP.post(
        "$BASE/upload/$(enc("(exec (\$thread \$priority) \$patterns \$templates)"))/$(enc("(exec (\$thread \$priority) \$patterns \$templates)"))",
        [], init_exec)
    @test r3.status == 200
    @test wait_eq("$BASE/status/$(enc("(exec (metta_thread_basic \$priority) \$p \$t)"))", "pathClear")

    # ── Step 4: Run metta_thread at metta_thread_basic ───────────────────
    r4 = HTTP.get("$BASE/metta_thread?location=metta_thread_basic")
    @test r4.status == 200
    finished = wait_eq("$BASE/status/$(enc("(exec metta_thread_basic)"))", "pathClear", 20.0)
    @test finished

    # ── Step 5: Run state-cleanup thread ─────────────────────────────────
    r5 = HTTP.get("$BASE/metta_thread?location=$(enc("(metta_thread_basic state)"))")
    @test r5.status == 200
    finished2 = wait_eq("$BASE/status/$(enc("(exec (metta_thread_basic state))"))", "pathClear", 15.0)
    @test finished2

    sleep(0.1)

    # ── Step 6: Export and verify 8 output atoms ─────────────────────────
    exp = String(HTTP.get(
        "$BASE/export/$(enc("((metta_thread_basic out) \$v)"))/$(enc("\$v"))").body)
    lines = sort(filter(!isempty, split(exp, "\n")))
    println("Export ($(length(lines)) lines): $lines")

    @test length(lines) == 8
    expected = sort(["(val a b)", "(val b a)", "(val c d)", "(val d c)",
                     "(val e f)", "(val f e)", "(val g h)", "(val h g)"])
    @test lines == expected
end

HTTP.get("$BASE/stop"; readtimeout=2)
println("metta_thread_basic test complete.")
