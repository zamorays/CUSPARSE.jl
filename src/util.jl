#custom extenstion of CudaArray in CUDArt for sparse vectors/matrices
#using CSC format for interop with Julia's native sparse functionality

import Base: length, size, ndims, eltype, similar, pointer, stride,
    copy, convert, reinterpret, show, summary, copy!, get!, fill!, issymmetric,
    ishermitian, isupper, islower
import Base.LinAlg: BlasFloat, Hermitian, HermOrSym
import CUDArt: device, to_host, free
using Compat

@compat abstract type AbstractCudaSparseArray{Tv,N} <: AbstractSparseArray{Tv,Cint,N} end
@compat const AbstractCudaSparseVector{Tv} = AbstractCudaSparseArray{Tv,1}
@compat const AbstractCudaSparseMatrix{Tv} = AbstractCudaSparseArray{Tv,2}

"""
Container to hold sparse vectors on the GPU, similar to `SparseVector` in base Julia.
"""
type CudaSparseVector{Tv} <: AbstractCudaSparseVector{Tv}
    iPtr::CudaArray{Cint,1}
    nzVal::CudaArray{Tv,1}
    dims::NTuple{2,Int}
    nnz::Cint
    dev::Int
    function CudaSparseVector{Tv}(iPtr::CudaVector{Cint}, nzVal::CudaVector{Tv}, dims::Int, nnz::Cint, dev::Int)
        new(iPtr,nzVal,(dims,1),nnz,dev)
    end
end

"""
Container to hold sparse matrices in compressed sparse column (CSC) format on
the GPU, similar to `SparseMatrixCSC` in base Julia.

**Note**: Most CUSPARSE operations work with CSR formatted matrices, rather
than CSC.
"""
type CudaSparseMatrixCSC{Tv} <: AbstractCudaSparseMatrix{Tv}
    colPtr::CudaArray{Cint,1}
    rowVal::CudaArray{Cint,1}
    nzVal::CudaArray{Tv,1}
    dims::NTuple{2,Int}
    nnz::Cint
    dev::Int

    function CudaSparseMatrixCSC{Tv}(colPtr::CudaVector{Cint}, rowVal::CudaVector{Cint}, nzVal::CudaVector{Tv}, dims::NTuple{2,Int}, nnz::Cint, dev::Int)
        new(colPtr,rowVal,nzVal,dims,nnz,dev)
    end
end

"""
Container to hold sparse matrices in compressed sparse row (CSR) format on the
GPU.

**Note**: Most CUSPARSE operations work with CSR formatted matrices, rather
than CSC.
"""
type CudaSparseMatrixCSR{Tv} <: AbstractCudaSparseMatrix{Tv}
    rowPtr::CudaArray{Cint,1}
    colVal::CudaArray{Cint,1}
    nzVal::CudaArray{Tv,1}
    dims::NTuple{2,Int}
    nnz::Cint
    dev::Int

    function CudaSparseMatrixCSR{Tv}(rowPtr::CudaVector{Cint}, colVal::CudaVector{Cint}, nzVal::CudaVector{Tv}, dims::NTuple{2,Int}, nnz::Cint, dev::Int)
        new(rowPtr,colVal,nzVal,dims,nnz,dev)
    end
end

"""
Container to hold sparse matrices in block compressed sparse row (BSR) format on
the GPU. BSR format is also used in Intel MKL, and is suited to matrices that are
"block" sparse - rare blocks of non-sparse regions.
"""
type CudaSparseMatrixBSR{Tv} <: AbstractCudaSparseMatrix{Tv}
    rowPtr::CudaArray{Cint,1}
    colVal::CudaArray{Cint,1}
    nzVal::CudaArray{Tv,1}
    dims::NTuple{2,Int}
    blockDim::Cint
    dir::SparseChar
    nnz::Cint
    dev::Int

    function CudaSparseMatrixBSR{Tv}(rowPtr::CudaVector{Cint}, colVal::CudaVector{Cint}, nzVal::CudaVector{Tv}, dims::NTuple{2,Int},blockDim::Cint, dir::SparseChar, nnz::Cint, dev::Int)
        new(rowPtr,colVal,nzVal,dims,blockDim,dir,nnz,dev)
    end
end

"""
Container to hold sparse matrices in NVIDIA's hybrid (HYB) format on the GPU.
HYB format is an opaque struct, which can be converted to/from using
CUSPARSE routines.
"""
@compat const cusparseHybMat_t = Ptr{Void}
type CudaSparseMatrixHYB{Tv} <: AbstractCudaSparseMatrix{Tv}
    Mat::cusparseHybMat_t
    dims::NTuple{2,Int}
    nnz::Cint
    dev::Int

    function CudaSparseMatrixHYB(Mat::cusparseHybMat_t, dims::NTuple{2,Int}, nnz::Cint, dev::Int)
        new(Mat,dims,nnz,dev)
    end
end

"""
Utility union type of [`CudaSparseMatrixCSC`](@ref), [`CudaSparseMatrixCSR`](@ref),
and `Hermitian` and `Symmetric` versions of these two containers. A function accepting
this type can make use of performance improvements by only indexing one triangle of the
matrix if it is guaranteed to be hermitian/symmetric.
"""
@compat const CompressedSparse{T} = Union{CudaSparseMatrixCSC{T},CudaSparseMatrixCSR{T},HermOrSym{T,CudaSparseMatrixCSC{T}},HermOrSym{T,CudaSparseMatrixCSR{T}}}

"""
Utility union type of [`CudaSparseMatrixCSC`](@ref), [`CudaSparseMatrixCSR`](@ref),
[`CudaSparseMatrixBSR`](@ref), and [`CudaSparseMatrixHYB`](@ref).
"""
@compat const CudaSparseMatrix{T} = Union{CudaSparseMatrixCSC{T},CudaSparseMatrixCSR{T}, CudaSparseMatrixBSR{T}, CudaSparseMatrixHYB{T}}

Hermitian{T}(Mat::CudaSparseMatrix{T}) = Hermitian{T,typeof(Mat)}(Mat,'U')

length(g::CudaSparseVector) = prod(g.dims)
size(g::CudaSparseVector) = g.dims
ndims(g::CudaSparseVector) = 1
length(g::CudaSparseMatrix) = prod(g.dims)
size(g::CudaSparseMatrix) = g.dims
ndims(g::CudaSparseMatrix) = 2

function size{T}(g::CudaSparseVector{T}, d::Integer)
    if d == 1
        return g.dims[d]
    elseif d > 1
        return 1
    else
        throw(ArgumentError("dimension must be ≥ 1, got $d"))
    end
end

function size{T}(g::CudaSparseMatrix{T}, d::Integer)
    if d in [1, 2]
        return g.dims[d]
    elseif d > 1
        return 1
    else
        throw(ArgumentError("dimension must be ≥ 1, got $d"))
    end
end

issymmetric{T}(M::Union{CudaSparseMatrixCSC{T},CudaSparseMatrixCSR{T}}) = false
ishermitian{T}(M::Union{CudaSparseMatrixCSC{T},CudaSparseMatrixCSR{T}}) = false
issymmetric{T}(M::Symmetric{T,CudaSparseMatrixCSC{T}}) = true
ishermitian{T}(M::Hermitian{T,CudaSparseMatrixCSC{T}}) = true

for mat_type in [:CudaSparseMatrixCSC, :CudaSparseMatrixCSR, :CudaSparseMatrixBSR, :CudaSparseMatrixHYB]
    @eval begin
        isupper{T}(M::UpperTriangular{T,$mat_type{T}}) = true
        islower{T}(M::UpperTriangular{T,$mat_type{T}}) = false
    end
end
eltype{T}(g::CudaSparseMatrix{T}) = T
device(A::CudaSparseMatrix)       = A.dev
device(A::SparseMatrixCSC)        = -1  # for host

if VERSION >= v"0.5.0-dev+742"
    function to_host{T}(Vec::CudaSparseVector{T})
        SparseVector(Vec.dims[1], to_host(Vec.iPtr), to_host(Vec.nzVal))
    end
else
    function to_host{T}(Vec::CudaSparseVector{T})
        sparsevec(to_host(Vec.iPtr), to_host(Vec.nzVal), Vec.dims[1])
    end
end

function to_host{T}(Mat::CudaSparseMatrixCSC{T})
    SparseMatrixCSC(Mat.dims[1], Mat.dims[2], to_host(Mat.colPtr), to_host(Mat.rowVal), to_host(Mat.nzVal))

end
function to_host{T}(Mat::CudaSparseMatrixCSR{T})
    rowPtr = to_host(Mat.rowPtr)
    colVal = to_host(Mat.colVal)
    nzVal = to_host(Mat.nzVal)
    #construct Is
    I = similar(colVal)
    counter = 1
    for row = 1 : size(Mat)[1], k = rowPtr[row] : (rowPtr[row+1]-1)
        I[counter] = row
        counter += 1
    end
    return sparse(I,colVal,nzVal,Mat.dims[1],Mat.dims[2])
end

summary(g::CudaSparseMatrix) = string(g)
summary(g::CudaSparseVector) = string(g)

CudaSparseVector{T<:BlasFloat,Ti<:Integer}(iPtr::Vector{Ti}, nzVal::Vector{T}, dims::Int) = CudaSparseVector{T}(CudaArray(convert(Vector{Cint},iPtr)), CudaArray(nzVal), dims, convert(Cint,length(nzVal)), device())
CudaSparseVector{T<:BlasFloat,Ti<:Integer}(iPtr::CudaArray{Ti}, nzVal::CudaArray{T}, dims::Int) = CudaSparseVector{T}(iPtr, nzVal, dims, convert(Cint,length(nzVal)), device())

CudaSparseMatrixCSC{T<:BlasFloat,Ti<:Integer}(colPtr::Vector{Ti}, rowVal::Vector{Ti}, nzVal::Vector{T}, dims::NTuple{2,Int}) = CudaSparseMatrixCSC{T}(CudaArray(convert(Vector{Cint},colPtr)), CudaArray(convert(Vector{Cint},rowVal)), CudaArray(nzVal), dims, convert(Cint,length(nzVal)), device())
CudaSparseMatrixCSC{T<:BlasFloat,Ti<:Integer}(colPtr::CudaArray{Ti}, rowVal::CudaArray{Ti}, nzVal::CudaArray{T}, dims::NTuple{2,Int}) = CudaSparseMatrixCSC{T}(colPtr, rowVal, nzVal, dims, convert(Cint,length(nzVal)), device())
CudaSparseMatrixCSC{T<:BlasFloat,Ti<:Integer}(colPtr::CudaArray{Ti}, rowVal::CudaArray{Ti}, nzVal::CudaArray{T}, nnz, dims::NTuple{2,Int}) = CudaSparseMatrixCSC{T}(colPtr, rowVal, nzVal, dims, nnz, device())

CudaSparseMatrixCSR{T}(rowPtr::CudaArray, colVal::CudaArray, nzVal::CudaArray{T}, dims::NTuple{2,Int}) = CudaSparseMatrixCSR{T}(rowPtr, colVal, nzVal, dims, convert(Cint,length(nzVal)), device())
CudaSparseMatrixCSR{T}(rowPtr::CudaArray, colVal::CudaArray, nzVal::CudaArray{T}, nnz, dims::NTuple{2,Int}) = CudaSparseMatrixCSR{T}(rowPtr, colVal, nzVal, dims, nnz, device())

CudaSparseMatrixBSR{T}(rowPtr::CudaArray, colVal::CudaArray, nzVal::CudaArray{T}, blockDim, dir, nnz, dims::NTuple{2,Int}) = CudaSparseMatrixBSR{T}(rowPtr, colVal, nzVal, dims, blockDim, dir, nnz, device())

if VERSION >= v"0.5.0-dev+742"
    CudaSparseVector(Vec::SparseVector)    = CudaSparseVector(Vec.nzind, Vec.nzval, size(Vec)[1])
    CudaSparseMatrixCSC(Vec::SparseVector)    = CudaSparseMatrixCSC([1], Vec.nzind, Vec.nzval, size(Vec))
end
CudaSparseVector(Mat::SparseMatrixCSC) = size(Mat,2) == 1 ? CudaSparseVector(Mat.rowval, Mat.nzval, size(Mat)[1]) : throw(ArgumentError())
CudaSparseMatrixCSC(Mat::SparseMatrixCSC) = CudaSparseMatrixCSC(Mat.colptr, Mat.rowval, Mat.nzval, size(Mat))
CudaSparseMatrixCSR(Mat::SparseMatrixCSC) = switch2csr(CudaSparseMatrixCSC(Mat))

similar(Vec::CudaSparseVector) = CudaSparseVector(copy(Vec.iPtr), similar(Vec.nzVal), Vec.dims[1])
similar(Mat::CudaSparseMatrixCSC) = CudaSparseMatrixCSC(copy(Mat.colPtr), copy(Mat.rowVal), similar(Mat.nzVal), Mat.nnz, Mat.dims)
similar(Mat::CudaSparseMatrixCSR) = CudaSparseMatrixCSR(copy(Mat.rowPtr), copy(Mat.colVal), similar(Mat.nzVal), Mat.nnz, Mat.dims)
similar(Mat::CudaSparseMatrixBSR) = CudaSparseMatrixBSR(copy(Mat.rowPtr), copy(Mat.colVal), similar(Mat.nzVal), Mat.blockDim, Mat.dir, Mat.nnz, Mat.dims)

function copy!(dst::CudaSparseVector, src::CudaSparseVector; stream=null_stream)
    if dst.dims != src.dims
        throw(ArgumentError("Inconsistent Sparse Vector size"))
    end
    copy!( dst.iPtr, src.iPtr )
    copy!( dst.nzVal, src.nzVal )
    dst.nnz = src.nnz
    dst
end

function copy!(dst::CudaSparseMatrixCSC, src::CudaSparseMatrixCSC; stream=null_stream)
    if dst.dims != src.dims
        throw(ArgumentError("Inconsistent Sparse Matrix size"))
    end
    copy!( dst.colPtr, src.colPtr )
    copy!( dst.rowVal, src.rowVal )
    copy!( dst.nzVal, src.nzVal )
    dst.nnz = src.nnz
    dst
end

function copy!(dst::CudaSparseMatrixCSR, src::CudaSparseMatrixCSR; stream=null_stream)
    if dst.dims != src.dims
        throw(ArgumentError("Inconsistent Sparse Matrix size"))
    end
    copy!( dst.rowPtr, src.rowPtr )
    copy!( dst.colVal, src.colVal )
    copy!( dst.nzVal, src.nzVal )
    dst.nnz = src.nnz
    dst
end

function copy!(dst::CudaSparseMatrixBSR, src::CudaSparseMatrixBSR; stream=null_stream)
    if dst.dims != src.dims
        throw(ArgumentError("Inconsistent Sparse Matrix size"))
    end
    copy!( dst.rowPtr, src.rowPtr )
    copy!( dst.colVal, src.colVal )
    copy!( dst.nzVal, src.nzVal )
    dst.dir = src.dir
    dst.nnz = src.nnz
    dst
end

function copy!(dst::CudaSparseMatrixHYB, src::CudaSparseMatrixHYB; stream=null_stream)
    if dst.dims != src.dims
        throw(ArgumentError("Inconsistent Sparse Matrix size"))
    end
    dst.Mat = src.Mat
    dst.nnz = src.nnz
    dst
end

copy(Vec::CudaSparseVector; stream=null_stream) = copy!(similar(Vec),Vec;stream=null_stream)
copy(Mat::CudaSparseMatrixCSC; stream=null_stream) = copy!(similar(Mat),Mat;stream=null_stream)
copy(Mat::CudaSparseMatrixCSR; stream=null_stream) = copy!(similar(Mat),Mat;stream=null_stream)
copy(Mat::CudaSparseMatrixBSR; stream=null_stream) = copy!(similar(Mat),Mat;stream=null_stream)
