module CUDAdrv

using CUDAapi

using Printf
using Libdl


## discovery

# minimal versions of certain API calls for during bootstrap
macro pre_apicall(libpath, fn, types, args...)
    quote
        lib = Libdl.dlopen($(esc(libpath)))
        sym = Libdl.dlsym(lib, $(esc(fn)))

        ccall(sym, Cint, $(esc(types)), $(map(esc, args)...))
    end
end
function pre_version(libpath)
    ref = Ref{Cint}()
    status = @pre_apicall(libpath, :cuDriverGetVersion, (Ptr{Cint}, ), ref)
    @assert status == 0
    return VersionNumber(ref[] ÷ 1000, mod(ref[], 100) ÷ 10)
end

const configured, libcuda, libcuda_version = try
    # NOTE: on macOS, the driver is part of the toolkit
    toolkit_dirs = find_toolkit()

    libcuda = find_cuda_library("cuda", toolkit_dirs)
    if libcuda == nothing
        error("Could not find CUDA driver library")
    end
    Base.include_dependency(libcuda)

    libcuda_version = pre_version(libcuda)

    true, libcuda, libcuda_version
catch ex
    @error "Could not configure CUDAdrv.jl" exception=(ex,catch_backtrace())
    # default (non-functional) values for critical variables,
    # making it possible to _load_ the package at all times.
    false, nothing, v"5.5"
end

# backwards-compatible flags
const libcuda_vendor = "NVIDIA"


## source code includes

include("base.jl")

# CUDA Driver API wrappers
include("init.jl")
include("errors.jl")
include("version.jl")
include("devices.jl")
include("context.jl")
include(joinpath("context", "primary.jl"))
include("stream.jl")
include("pointer.jl")
include("memory.jl")
include("module.jl")
include("events.jl")
include("execution.jl")
include("profile.jl")
include("occupancy.jl")

include("deprecated.jl")


## initialization

function __init__()
    configured || return

    if !ispath(libcuda) || version() != libcuda_version
        cachefile = Base.compilecache(Base.PkgId(CUDAdrv))
        rm(cachefile)
        error("Your set-up changed, and CUDAdrv.jl needs to be reconfigured. Please load the package again.")
    end

    if haskey(ENV, "_") && basename(ENV["_"]) == "rr"
        @warn "Running under rr, which is incompatible with CUDA; disabling initialization."
    else
        init()
    end
end

end
