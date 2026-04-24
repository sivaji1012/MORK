# test/integration/logic_query.jl — ports fn logic_query() in kernel/src/main.rs
# Equational logic: bi-directional equation search reaches exactly 79 atoms.
using MORK, Test

@testset "logic_query — equational logic produces 79 atoms" begin
    s = new_space()
    space_add_all_sexpr!(s, """
(exec 0 (, (axiom (= \$lhs \$rhs)) (axiom (= \$rhs \$lhs))) (, (reversed \$lhs \$rhs)))
    """)
    # Load axioms tagged under (axiom ...)
    axioms = """
(= (L \$x \$y \$z) (R \$x \$y \$z))
(= (L 1 \$x \$y) (R 1 \$x \$y))
(= (R \$x (L \$x \$y \$z) \$w) \$x)
(= (R \$x (R \$x \$y \$z) \$w) \$x)
(= (R \$x (L \$x \$y \$z) \$x) (L \$x (L \$x \$y \$z) \$x))
(= (L \$x \$y (\\ \$y \$z)) (L \$x \$y \$z))
(= (L \$x \$y (* \$z \$y)) (L \$x \$y \$z))
(= (L \$x \$y (\\ \$z 1)) (L \$x \$z \$y))
(= (L \$x \$y (\\ \$z \$y)) (L \$x \$z \$y))
(= (L \$x 1 (\\ \$y 1)) (L \$x \$y 1))
(= (T \$x (L \$x \$y \$z)) \$x)
(= (T \$x (R \$x \$y \$z)) \$x)
(= (T \$x (a \$x \$y \$z)) \$x)
(= (T \$x (\\ (a \$x \$y \$z) \$w)) (T \$x \$w))
(= (T \$x (* \$y \$y)) (T \$x (\\ (a \$x \$z \$w) (* \$y \$y))))
(= (R (/ 1 \$x) \$x (\\ \$x 1)) (\\ \$x 1))
(= (\\ \$x 1) (/ 1 (L \$x \$x (\\ \$x 1))))
(= (L \$x \$x \$x) (* (K \$x (\\ \$x 1)) \$x))
    """
    for line in split(strip(axioms), "\n")
        isempty(strip(line)) && continue
        space_add_all_sexpr!(s, "(axiom $line)\n")
    end
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    @test space_val_count(s) == 79
end
