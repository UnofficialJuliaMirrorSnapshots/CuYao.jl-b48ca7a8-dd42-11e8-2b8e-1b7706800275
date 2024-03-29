using LinearAlgebra, Yao.ConstGate
using Test, Random
using CuYao
using StatsBase: Weights
using StaticArrays
using QuAlgorithmZoo
using CuArrays

function CuYao.expect(stat::StatFunctional{2, <:Function}, xs::CuVector{T}) where T
    N = length(xs)
    s = reduce(+, stat.data.(xs', xs))
    d = mapreduce(xi->stat.data(xi, xi), +, xs)
    (s-d)/(N*(N-1))
end

function CuYao.expect(stat::StatFunctional{2, <:Function}, xs::CuVector, ys::CuVector)
    M = length(xs)
    N = length(ys)
    reduce(+, stat.data.(xs', ys))/M/N
end
@testset "expect stat functional" begin
    sf(x, y) = abs(x-y)
    a = randn(1024)
    ca = a |> cu
    b = randn(1024)
    cb = b |> cu
    @test expect(StatFunctional{2}(sf), a, b) ≈ expect(StatFunctional{2}(sf), ca, cb)
    @test expect(StatFunctional{2}(sf), a) ≈ expect(StatFunctional{2}(sf), ca)
end

function loss_expect!(circuit::AbstractBlock, op::AbstractBlock)
    N = nqubits(circuit)
    function loss!(ψ::AbstractRegister, θ::Vector)
        params = parameters(circuit)
        dispatch!(circuit, θ)
        ψ |> circuit
        popdispatch!(circuit, params)
        expect(op, ψ)
    end
end

@testset "BP diff" begin
    c = put(4, 3=>Rx(0.5)) |> autodiff(:BP)
    cad = c'
    @test mat(cad) == mat(c)'

    circuit = chain(4, repeat(4, H, 1:4), put(4, 3=>Rz(0.5)) |> autodiff(:BP), control(2, 1=>X), put(4, 4=>Ry(0.2)) |> autodiff(:BP))
    op = put(4, 3=>Y)
    θ = [0.1, 0.2]
    dispatch!(circuit, θ)
    loss! = loss_expect!(circuit, op)
    ψ0 = rand_state(4) |> cu
    ψ = copy(ψ0) |> circuit

    # get gradient
    δ = ψ |> op
    backward!(δ, circuit)
    g1 = gradient(circuit)

    g2 = zero(θ)
    η = 0.01
    for i in 1:length(θ)
        θ1 = copy(θ)
        θ2 = copy(θ)
        θ1[i] -= 0.5η
        θ2[i] += 0.5η
        g2[i] = (loss!(copy(ψ0), θ2) - loss!(copy(ψ0), θ1))/η |> real
    end
    g3 = opdiff.(() -> copy(ψ0) |> circuit, collect_blocks(BPDiff, circuit), Ref(op))
    @test δ isa GPUReg
    @test ψ isa GPUReg
    @test isapprox.(g1, g2, atol=1e-5) |> all
    @test isapprox.(g2, g3, atol=1e-5) |> all
end

@testset "stat diff" begin
    Random.seed!(2)
    nbit = 4
    f(x::Number, y::Number) = Float64(abs(x-y) < 1.5)
    x = 0:1<<nbit-1
    h = f.(x', x)
    V = StatFunctional(h)
    VF = StatFunctional{2}(f)
    prs = [1=>2, 2=>3, 3=>1]
    c = chain(4, repeat(4, H, 1:4), put(4, 3=>Rz(0.5)) |> autodiff(:BP), control(2, 1=>X), put(4, 4=>Ry(0.2)) |> autodiff(:QC))
    dispatch!(c, :random)
    dbs = collect_blocks(AbstractDiff, c)

    p0 = zero_state(nbit) |> c |> probs |> Weights
    sample0 = measure(zero_state(nbit) |> c, nshots=5000)
    loss0 = expect(V, p0)
    gradsn = numdiff.(()->expect(V, zero_state(nbit) |> c |> probs |> Weights), dbs)
    gradse = statdiff.(()->zero_state(nbit) |> c |> probs |> Weights, dbs, Ref(V), initial=p0)
    gradsf = statdiff.(()->measure(zero_state(nbit) |> c, nshots=5000), dbs, Ref(VF), initial=sample0)
    @test all(isapprox.(gradse, gradsn, atol=1e-4))
    @test norm(gradsf-gradse)/norm(gradsf) <= 0.2

    # 1D
    h = randn(1<<nbit)
    V = StatFunctional(h)
    c = chain(4, repeat(4, H, 1:4), put(4, 3=>Rz(0.5)) |> autodiff(:BP), control(2, 1=>X), put(4, 4=>Ry(0.2)) |> autodiff(:QC))
    dispatch!(c, :random)
    dbs = collect_blocks(AbstractDiff, c)

    p0 = zero_state(nbit) |> c |> probs
    loss0 = expect(V, p0 |> as_weights)
    gradsn = numdiff.(()->expect(V, zero_state(nbit) |> c |> probs |> as_weights), dbs)
    gradse = statdiff.(()->zero_state(nbit) |> c |> probs |> as_weights, dbs, Ref(V))
    @test all(isapprox.(gradse, gradsn, atol=1e-4))
end
