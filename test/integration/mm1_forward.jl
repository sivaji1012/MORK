# test/integration/mm1_forward.jl — ports fn mm1_forward() in kernel/src/main.rs
# MM1 forward: prove ⊢ (t = t) using typed constructors + metta_calculus.
# Upstream runs up to 128 steps; we cap at 10k and check key milestones.
using MORK, Test

@testset "mm1_forward — prove ⊢ (t = t) via forward chaining" begin
    s = new_space()
    space_add_all_sexpr!(s, """
(kb (: (+) (-> (term) (-> (term) (term)))))
(kb (: (=) (-> (term) (-> (term) (wff)))))
(kb (: (t) (term)))
(kb (: (0) (term)))
(kb (: (a2) (-> (: \$a (term)) (: ((=) ((+) \$a (0)) \$a) (|-)))))
(kb (: (a1) (-> (: \$a (term)) (: \$b (term)) (: \$c (term)) (: ((->) ((=) \$a \$b) ((->) ((=) \$a \$c) ((=) \$b \$c))) (|-)))))
(kb (: (mp) (-> (: \$P (wff)) (: \$Q (wff)) (: \$P (|-)) (: ((->) \$P \$Q) (|-)) (: \$Q (|-)))))
(exec (0 lift) (, (kb (: \$t \$T))) (, (ev (: \$t \$T))))
(exec (1 tpl-apply)
  (, (ev (: \$x (term))) (ev (: \$y (term))))
  (, (ev (: ((+) \$x \$y) (term)))))
(exec (1 weq-apply)
  (, (ev (: \$a (term))) (ev (: \$b (term))))
  (, (ev (: ((=) \$a \$b) (wff)))))
(exec (1 a2-instantiate-t)
  (, (ev (: \$a (term))))
  (, (ev (: ((=) ((+) \$a (0)) \$a) (|-)))))
(exec (2 derive-P-to-Q-direct3)
  (, (ev (: \$P (wff))) (ev (: \$P (|-))) (ev (: ((->) \$P \$IMP) (|-))) (ev (: \$IMP (wff))))
  (, (ev (: \$IMP (|-)))))
(exec (3 assemble-final-proof-direct)
  (, (ev (: \$P (wff))) (ev (: \$P (|-))) (ev (: ((->) \$P \$Q) (|-))) (ev (: \$Q (wff))))
  (, (ev (: \$Q (|-)))))
    """)
    steps = space_metta_calculus!(s, 10_000)
    @test steps < 10_000
    result = space_dump_all_sexpr(s)
    # Core milestone: (ev (: (t) (term))) must be derived by lift rule
    @test occursin("(ev (: (t) (term)))", result)
    # (ev (: ((+) (t) (0)) (term))) via tpl-apply
    @test occursin("(ev (: ((+) (t) (0)) (term)))", result)
    # a2 instantiation: ⊢ ((+) (t) (0)) = (t)
    @test occursin("(ev (: ((=) ((+) (t) (0)) (t)) (|-)))", result)
end
