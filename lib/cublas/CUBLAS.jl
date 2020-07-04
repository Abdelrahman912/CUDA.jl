module CUBLAS

using ..APIUtils

using ..CUDA
using ..CUDA: CUstream, cuComplex, cuDoubleComplex, libraryPropertyType, cudaDataType
using ..CUDA: libcublas, unsafe_free!, @retry_reclaim

using LinearAlgebra

using CEnum

# core library
include("libcublas_common.jl")
include("error.jl")
include("libcublas.jl")

# low-level wrappers
include("util.jl")
include("wrappers.jl")

# high-level integrations
include("linalg.jl")

# thread cache for task-local library handles
const thread_handles = Vector{Union{Nothing,cublasHandle_t}}()
const thread_xt_handles = Vector{Union{Nothing,cublasXtHandle_t}}()

function handle()
    tid = Threads.threadid()
    if @inbounds thread_handles[tid] === nothing
        ctx = context()
        thread_handles[tid] = get!(task_local_storage(), (:CUBLAS, ctx)) do
            handle = cublasCreate()
            finalizer(current_task()) do task
                CUDA.isvalid(ctx) || return
                context!(ctx) do
                    cublasDestroy_v2(handle)
                end
            end

            # enable tensor math mode if our device supports it, and fast math is enabled
            dev = device()
            if Base.JLOptions().fast_math == 1 && capability(dev) >= v"7.0" && version() >= v"9"
                cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH)
            end

            handle
        end
    end
    @inbounds thread_handles[tid]
end

function xt_handle()
    tid = Threads.threadid()
    if @inbounds thread_xt_handles[tid] === nothing
        ctx = context()
        thread_xt_handles[tid] = get!(task_local_storage(), (:CUBLASxt, ctx)) do
            handle = cublasXtCreate()
            finalizer(current_task()) do task
                CUDA.isvalid(ctx) || return
                context!(ctx) do
                    cublasXtDestroy(handle)
                end
            end

            # select the devices
            # TODO: this is weird, since we typically use a single device per thread/context
            devs = convert.(Cint, CUDA.devices())
            cublasXtDeviceSelect(handle, length(devs), devs)

            handle
        end
    end
    @inbounds thread_xt_handles[tid]
end

function __init__()
    resize!(thread_handles, Threads.nthreads())
    fill!(thread_handles, nothing)

    resize!(thread_xt_handles, Threads.nthreads())
    fill!(thread_xt_handles, nothing)

    CUDA.atcontextswitch() do tid, ctx
        thread_handles[tid] = nothing
        thread_xt_handles[tid] = nothing
    end

    CUDA.attaskswitch() do tid, task
        thread_handles[tid] = nothing
        thread_xt_handles[tid] = nothing
    end
end

end
