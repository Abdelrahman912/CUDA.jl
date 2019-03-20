# Native execution support

export @cuda, cudaconvert, cufunction, nearest_warpsize


## kernel object and query functions

struct Kernel{F,TT}
    ctx::CuContext
    mod::CuModule
    fun::CuFunction
end

"""
    version(k::Kernel)

Queries the PTX and SM versions a kernel was compiled for.
Returns a named tuple.
"""
function version(k::Kernel)
    attr = attributes(k.fun)
    binary_ver = VersionNumber(divrem(attr[CUDAdrv.FUNC_ATTRIBUTE_BINARY_VERSION],10)...)
    ptx_ver = VersionNumber(divrem(attr[CUDAdrv.FUNC_ATTRIBUTE_PTX_VERSION],10)...)
    return (ptx=ptx_ver, binary=binary_ver)
end

"""
    memory(k::Kernel)

Queries the local, shared and constant memory usage of a compiled kernel in bytes.
Returns a named tuple.
"""
function memory(k::Kernel)
    attr = attributes(k.fun)
    local_mem = attr[CUDAdrv.FUNC_ATTRIBUTE_LOCAL_SIZE_BYTES]
    shared_mem = attr[CUDAdrv.FUNC_ATTRIBUTE_SHARED_SIZE_BYTES]
    constant_mem = attr[CUDAdrv.FUNC_ATTRIBUTE_CONST_SIZE_BYTES]
    return (:local=>local_mem, shared=shared_mem, constant=constant_mem)
end

"""
    registers(k::Kernel)

Queries the register usage of a kernel.
"""
function registers(k::Kernel)
    attr = attributes(k.fun)
    return attr[CUDAdrv.FUNC_ATTRIBUTE_NUM_REGS]
end

"""
    maxthreads(k::Kernel)

Queries the maximum amount of threads a kernel can use in a single block.
"""
function maxthreads(k::Kernel)
    attr = attributes(k.fun)
    return attr[CUDAdrv.FUNC_ATTRIBUTE_MAX_THREADS_PER_BLOCK]
end


## helper functions

# split keyword arguments to `@cuda` into ones affecting the macro itself, the compiler and
# the code it generates, or the execution
function split_kwargs(kwargs)
    macro_kws    = [:dynamic]
    compiler_kws = [:minthreads, :maxthreads, :blocks_per_sm, :maxregs]
    call_kws     = [:blocks, :threads, :shmem, :stream]
    macro_kwargs = []
    compiler_kwargs = []
    call_kwargs = []
    for kwarg in kwargs
        if Meta.isexpr(kwarg, :(=))
            key,val = kwarg.args
            if isa(key, Symbol)
                if key in macro_kws
                    push!(macro_kwargs, kwarg)
                elseif key in compiler_kws
                    push!(compiler_kwargs, kwarg)
                elseif key in call_kws
                    push!(call_kwargs, kwarg)
                else
                    throw(ArgumentError("unknown keyword argument '$key'"))
                end
            else
                throw(ArgumentError("non-symbolic keyword '$key'"))
            end
        else
            throw(ArgumentError("non-keyword argument like option '$kwarg'"))
        end
    end

    return macro_kwargs, compiler_kwargs, call_kwargs
end

# assign arguments to variables, handle splatting
function assign_args!(code, args)
    # handle splatting
    splats = map(arg -> Meta.isexpr(arg, :(...)), args)
    args = map(args, splats) do arg, splat
        splat ? arg.args[1] : arg
    end

    # assign arguments to variables
    vars = Tuple(gensym() for arg in args)
    map(vars, args) do var,arg
        push!(code.args, :($var = $(esc(arg))))
    end

    # convert the arguments, compile the function and call the kernel
    # while keeping the original arguments alive
    var_exprs = map(vars, args, splats) do var, arg, splat
         splat ? Expr(:(...), var) : var
    end

    return vars, var_exprs
end

# fast lookup of global world age
world_age() = ccall(:jl_get_tls_world_age, UInt, ())

# slow lookup of local method age
function method_age(f, tt)::UInt
    for m in Base._methods(f, tt, 1, typemax(UInt))
        return m[3].min_world
    end
    throw(MethodError(f, tt))
end


## adaptors

struct Adaptor end

# convert CUDAdrv pointers to CUDAnative pointers
Adapt.adapt_storage(to::Adaptor, p::CuPtr{T}) where {T} = DevicePtr{T,AS.Generic}(p)

# Base.RefValue isn't GPU compatible, so provide a compatible alternative
struct CuRefValue{T} <: Ref{T}
  x::T
end
Base.getindex(r::CuRefValue) = r.x
Adapt.adapt_structure(to::Adaptor, r::Base.RefValue) = CuRefValue(adapt(to, r[]))

# convenience function
"""
    cudaconvert(x)

This function is called for every argument to be passed to a kernel, allowing it to be
converted to a GPU-friendly format. By default, the function does nothing and returns the
input object `x` as-is.

Do not add methods to this function, but instead extend the underlying Adapt.jl package and
register methods for the the `CUDAnative.Adaptor` type.
"""
cudaconvert(arg) = adapt(Adaptor(), arg)


## high-level @cuda interface

"""
    @cuda [kwargs...] func(args...)

High-level interface for executing code on a GPU. The `@cuda` macro should prefix a call,
with `func` a callable function or object that should return nothing. It will be compiled to
a CUDA function upon first use, and to a certain extent arguments will be converted and
managed automatically using `cudaconvert`. Finally, a call to `CUDAdrv.cudacall` is
performed, scheduling a kernel launch on the current CUDA context.

Several keyword arguments are supported that influence the behavior of `@cuda`.
- `dynamic`: use dynamic parallelism to launch device-side kernels
- arguments that influence kernel compilation: see [`cufunction`](@ref)
- arguments that influence kernel execution: see [`CUDAnative.Kernel`](@ref)

The underlying operations (argument conversion, kernel compilation, kernel call) can be
performed explicitly when more control is needed, e.g. to reflect on the resource usage of a
kernel to determine the launch configuration. A host-side kernel launch is done as follows:

    args = ...
    GC.@preserve args begin
        kernel_args = cudaconvert.(args)
        kernel_tt = Tuple{Core.Typeof.(kernel_args)...}
        kernel = cufunction(f, kernel_tt; compilation_kwargs)
        kernel(kernel_args...; launch_kwargs)
    end
"""
macro cuda(ex...)
    # destructure the `@cuda` expression
    if length(ex) > 0 && ex[1].head == :tuple
        error("The tuple argument to @cuda has been replaced by keywords: `@cuda threads=... fun(args...)`")
    end
    call = ex[end]
    kwargs = ex[1:end-1]

    # destructure the kernel call
    if call.head != :call
        throw(ArgumentError("second argument to @cuda should be a function call"))
    end
    f = call.args[1]
    args = call.args[2:end]

    code = quote end
    macro_kwargs, compiler_kwargs, call_kwargs = split_kwargs(kwargs)
    vars, var_exprs = assign_args!(code, args)

    # handle keyword arguments that influence the macro's behavior
    dynamic = false
    for kwarg in macro_kwargs
        key,val = kwarg.args
        if key == :dynamic
            dynamic = val::Bool
        else
            throw(ArgumentError("Unsupported keyword argument '$key'"))
        end
    end

    if dynamic
        # dynamic, device-side kernel launch
        #
        # WIP
        # TODO: GC.@preserve?
        # TODO: error on, or support kwargs
        push!(code.args,
            quote
                # we're in kernel land already, so no need to convert arguments
                local kernel_tt = Tuple{$((:(Core.Typeof($var)) for var in var_exprs)...)}
                local kernel = dynamic_cufunction($(esc(f)), kernel_tt)
                dynamic_cudacall(kernel, kernel_tt, $(var_exprs...); $(map(esc, call_kwargs)...))
             end)
    else
        # regular, host-side kernel launch
        #
        # convert the arguments, call the compiler and launch the kernel
        # while keeping the original arguments alive
        push!(code.args,
            quote
                GC.@preserve $(vars...) begin
                    local kernel_args = cudaconvert.(($(var_exprs...),))
                    local kernel_tt = Tuple{Core.Typeof.(kernel_args)...}
                    local kernel = cufunction($(esc(f)), kernel_tt;
                                              $(map(esc, compiler_kwargs)...))
                    kernel(kernel_args...; $(map(esc, call_kwargs)...))
                end
             end)
    end

    return code
end

import CUDAdrv: CuDim3, CuStream_t

const cudaError_t = Cint
const cudaStream_t = CUDAdrv.CuStream_t

dynamic_cufunction(f::Core.Function, tt::Type=Tuple{}) =
    ccall("extern cudanativeCompileKernel", llvmcall, Ptr{Cvoid}, (Any, Any), f, tt)

@generated function dynamic_cudacall(f::Ptr{Cvoid}, tt::Type, args...;
                                     blocks::CuDim=1, threads::CuDim=1, shmem::Integer=0,
                                     stream::CuStream=CuDefaultStream())
    ex = quote
        Base.@_inline_meta
    end

    # convert the argument values to match the kernel's signature (specified by the user)
    # (this mimics `lower-ccall` in julia-syntax.scm)
    converted_args = Vector{Symbol}(undef, length(args))
    arg_ptrs = Vector{Symbol}(undef, length(args))
    for i in 1:length(args)
        converted_args[i] = gensym()
        arg_ptrs[i] = gensym()
        push!(ex.args, :($(converted_args[i]) = Base.cconvert($(args[i]), args[$i])))
        push!(ex.args, :($(arg_ptrs[i]) = Base.unsafe_convert($(args[i]), $(converted_args[i]))))
    end

    append!(ex.args, (quote
        #GC.@preserve $(converted_args...) begin
            launch(f, blocks, threads, shmem, stream, ($(arg_ptrs...),))
        #end
    end).args)

    return ex
end

@inline function launch(f::Ptr{Cvoid}, blocks::CuDim, threads::CuDim,
                        shmem::Int, stream::CuStream,
                        args...)
    blocks = CuDim3(blocks)
    threads = CuDim3(threads)

    buf = parameter_buffer(f, blocks, threads, shmem, args...)

    ccall("extern cudaLaunchDeviceV2", llvmcall, cudaError_t,
          (Ptr{Cvoid}, cudaStream_t),
          buf, stream)

    return
end

@generated function parameter_buffer(f::Ptr{Cvoid}, blocks::CuDim3, threads::CuDim3,
                                     shmem::Int, args...)
    # allocate a buffer
    ex = quote
        buf = ccall("extern cudaGetParameterBufferV2", llvmcall, Ptr{Cvoid},
                    (Ptr{Cvoid}, CuDim3, CuDim3, Cuint),
                    f, blocks, threads, shmem)
    end

    # store the parameters
    #
    # > Each individual parameter placed in the parameter buffer is required to be aligned.
    # > That is, each parameter must be placed at the n-th byte in the parameter buffer,
    # > where n is the smallest multiple of the parameter size that is greater than the
    # > offset of the last byte taken by the preceding parameter. The maximum size of the
    # > parameter buffer is 4KB.
    offset = 0
    for i in 1:length(args)
        buf_index = Base.ceil(Int, offset / sizeof(args[i])) + 1
        offset = buf_index * sizeof(args[i])
        push!(ex.args, :(
            unsafe_store!(Base.unsafe_convert(Ptr{$(args[i])}, buf), args[$i], $buf_index)
        ))
    end

    push!(ex.args, :(return buf))

    return ex
end


## APIs for manual compilation

const agecache = Dict{UInt, UInt}()
const compilecache = Dict{UInt, Kernel}()

"""
    cufunction(f, tt=Tuple{}; kwargs...)

Low-level interface to compile a function invocation for the currently-active GPU, returning
a callable kernel object. For a higher-level interface, use [`@cuda`](@ref).

The following keyword arguments are supported:
- `minthreads`: the required number of threads in a thread block
- `maxthreads`: the maximum number of threads in a thread block
- `blocks_per_sm`: a minimum number of thread blocks to be scheduled on a single
  multiprocessor
- `maxregs`: the maximum number of registers to be allocated to a single thread (only
  supported on LLVM 4.0+)

The output of this function is automatically cached, i.e. you can simply call `cufunction`
in a hot path without degrading performance. New code will be generated automatically, when
when function changes, or when different types or keyword arguments are provided.
"""
@generated function cufunction(f::Core.Function, tt::Type=Tuple{}; kwargs...)
    tt = Base.to_tuple_type(tt.parameters[1])
    sig = Base.signature_type(f, tt)
    t = Tuple(tt.parameters)

    precomp_key = hash(sig)  # precomputable part of the keys
    quote
        Base.@_inline_meta

        CUDAnative.maybe_initialize("cufunction")

        # look-up the method age
        key = hash(world_age(), $precomp_key)
        if haskey(agecache, key)
            age = agecache[key]
        else
            age = method_age(f, $t)
            agecache[key] = age
        end

        # compile the function
        ctx = CuCurrentContext()
        key = hash(age, $precomp_key)
        key = hash(ctx, key)
        key = hash(kwargs, key)
        for nf in 1:nfields(f)
            # mix in the values of any captured variable
            key = hash(getfield(f, nf), key)
        end
        if !haskey(compilecache, key)
            dev = device(ctx)
            cap = supported_capability(dev)
            fun, mod = compile(:cuda, cap, f, tt; kwargs...)
            kernel = Kernel{f,tt}(ctx, mod, fun)
            @debug begin
                ver = version(kernel)
                mem = memory(kernel)
                reg = registers(kernel)
                """Compiled $f to PTX $(ver.ptx) for SM $(ver.binary) using $reg registers.
                   Memory usage: $(Base.format_bytes(mem.local)) local, $(Base.format_bytes(mem.shared)) shared, $(Base.format_bytes(mem.constant)) constant"""
            end
            compilecache[key] = kernel
        end

        return compilecache[key]::Kernel{f,tt}
    end
end

@generated function (kernel::Kernel{F,TT})(args...; call_kwargs...) where {F,TT}
    sig = Base.signature_type(F, TT)
    args = (:F, (:( args[$i] ) for i in 1:length(args))...)

    # filter out ghost arguments that shouldn't be passed
    to_pass = map(!isghosttype, sig.parameters)
    call_t =                  Type[x[1] for x in zip(sig.parameters,  to_pass) if x[2]]
    call_args = Union{Expr,Symbol}[x[1] for x in zip(args, to_pass)            if x[2]]

    # replace non-isbits arguments (they should be unused, or compilation would have failed)
    # alternatively, make CUDAdrv allow `launch` with non-isbits arguments.
    for (i,dt) in enumerate(call_t)
        if !isbitstype(dt)
            call_t[i] = Ptr{Any}
            call_args[i] = :C_NULL
        end
    end

    # finalize types
    call_tt = Base.to_tuple_type(call_t)

    quote
        Base.@_inline_meta

        cudacall(kernel.fun, $call_tt, $(call_args...); call_kwargs...)
    end
end

# FIXME: there doesn't seem to be a way to access the documentation for the call-syntax,
#        so attach it to the type
"""
    (::Kernel)(args...; kwargs...)

Low-level interface to call a compiled kernel, passing GPU-compatible arguments in `args`.
For a higher-level interface, use [`@cuda`](@ref).

The following keyword arguments are supported:
- `threads` (defaults to 1)
- `blocks` (defaults to 1)
- `shmem` (defaults to 0)
- `stream` (defaults to the default stream)
"""
Kernel


## other

"""
    nearest_warpsize(dev::CuDevice, threads::Integer)

Return the nearest number of threads that is a multiple of the warp size of a device.

This is a common requirement, eg. when using shuffle intrinsics.
"""
function nearest_warpsize(dev::CuDevice, threads::Integer)
    ws = CUDAdrv.warpsize(dev)
    return threads + (ws - threads % ws) % ws
end
