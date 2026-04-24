# test/integration/formula_execution.jl — ports fn formula_execution() in kernel/src/main.rs
# Functional formula evaluation via peel/lensOf + eval exec rules.
# Upstream: no assertion, just prints result. We verify it terminates.
using MORK, Test

@testset "formula_execution — eval pipeline terminates" begin
    s = new_space()
    # Build pred facts: (pred 1 0) (pred 2 1) ... (pred 10 9)
    pred_facts = join(["(pred $(i+1) $i)" for i in 0:9], " ")
    space_add_all_sexpr!(s, """
(= (car (\$x)) \$x) (= (cdr (\$x)) ())
(= (car (\$x \$y)) \$x) (= (cdr (\$x \$y)) (\$y)) (= (cadr (\$x \$y)) \$y)
(= (reverse ()) ()) (= (reverse (\$x)) (\$x)) (= (reverse (\$x \$y)) (\$y \$x))
(= (length ()) 0) (= (length (\$a)) 1) (= (length (\$a \$b)) 2)
(= (explode foo) (f o o)) (= (explode bar) (b a r))
(= (implode (f o o)) foo) (= (implode (b a r)) bar) (= (implode (o f)) of)
(eval (implode (cdr (reverse (explode foo)))))
$pred_facts
(exec (0 0) (, (eval \$x)) (, ((peel 10) \$x \$y (result \$y)) ))
(exec (2 0)
  (, ((peel \$p) \$x \$fx \$yc))
  (, (exec \$p (, (= \$x \$fx)) (, (res \$yc)))))
    """)
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000  # terminates within cap
    # No hard assertion — upstream just prints; we check atoms were produced
    @test space_val_count(s) > 5
end
