# This file is a part of JuliaFEM.
# License is MIT: see https://github.com/JuliaFEM/Materials.jl/blob/master/LICENSE

module Increments

import LinearAlgebra: norm
import Tensors: tovoigt, fromvoigt

import ..AbstractMaterial, ..integrate_material!
import ..Utilities: Symm2

export find_dstrain!, uniaxial_increment!, biaxial_increment!, stress_driven_uniaxial_increment!

# The skeleton of the optimizer is always the same, so we provide it as a
# higher-order function. The individual specific optimizer functions
# (`update_dstrain!)` only need to define the "meat" of how to update `dstrain`.
"""
    find_dstrain!(material::AbstractMaterial, dstrain::AbstractVector{<:Real},
                  dt::Real, update_dstrain!::Function;
                  max_iter::Integer=50, tol::Real=1e-9)

Find a compatible strain increment for `material`.

The functions in this module are made to be able to easily simulate stress
states produced by some of the most common test machines. Take for example the
function `uniaxial_increment!`. In a push-pull machine (with a smooth specimen),
we know that the stress state is uniaxial (in the measuring volume), so given
the strain increment in the direction where the stress is nonzero, we find
a strain increment that produces zero stress in the other directions.

The `dstrain` supplied to this routine is the initial guess for the
optimization. At each iteration, it must be updated by the user-defined
corrector `update_dstrain!`, whose call signature is expected to be:

    update_dstrain!(dstrain::V, dstress::V, jacobian::AbstractArray{T})
        where V <: AbstractVector{T} where T <: Real
      -> err::Real

`dstrain` is the current value of the strain increment, in Voigt format.
Conversion to tensor format uses `offdiagscale=2.0`. The function must update
the Voigt format `dstrain` in-place.

`dstress = stress - stress0`, where `stress` is the stress state predicted by
integrating the material for one timestep of length `dt`, using the current
value of `dstrain` as a driving strain increment, and `stress0` is the stress
state stored in `materials.variables.stress`.

`jacobian` is ∂σij/∂εkl (`material.variables_new.jacobian`), as computed by the
material implementation. In many cases, the dstrain optimization can actually be
performed by a Newton-Raphson root finder, so we pass the jacobian to facilitate
writing the update formula for such a root finder.

The return value `err` must be an error measure (Real, >= 0).

The update is iterated at most `max_iter` times, until `err` falls below `tol`.

If `max_iter` is reached and the error measure is still `tol` or greater,
`ErrorException` is thrown.

Note the timestep is **not** committed; we call `integrate_material!`, but not
`update_material!`. Only `material.variables_new` is updated.
"""
function find_dstrain!(material::AbstractMaterial, dstrain::AbstractVector{<:Real},
                       dt::Real, update_dstrain!::Function;
                       max_iter::Integer=50, tol::Real=1e-9)
    stress0 = tovoigt(material.variables.stress)  # observed
    T = typeof(dstrain[1])
    # @debug "---START---"
    for i=1:max_iter
        # @debug "$i, $dstrain, $stress0, $(material.variables.stress)"
        material.ddrivers.time = dt
        material.ddrivers.strain = fromvoigt(Symm2{T}, dstrain; offdiagscale=2.0)
        integrate_material!(material)
        stress = tovoigt(material.variables_new.stress)  # predicted
        dstress = stress - stress0
        jacobian = tovoigt(material.variables_new.jacobian)
        e = update_dstrain!(dstrain, dstress, jacobian)
        if e < tol
            return nothing
        end
    end
    error("No convergence in strain increment")
end

"""
    uniaxial_increment!(material::AbstractMaterial, dstrain11::Real, dt::Real;
                        dstrain::AbstractVector{<:Real}=[dstrain11, -0.3*dstrain11, -0.3*dstrain11, 0.0, 0.0, 0.0],
                        max_iter::Integer=50, norm_acc::Real=1e-9)

Find a compatible strain increment for `material`.

The material state (`material.variables`) and the component 11 of the *strain*
increment are taken as prescribed. This routine computes the other components of
the strain increment such that the predicted stress state matches the stored
one.

See `find_dstrain!`.
"""
function uniaxial_increment!(material::AbstractMaterial, dstrain11::Real, dt::Real;
                             dstrain::AbstractVector{<:Real}=[dstrain11, -0.3*dstrain11, -0.3*dstrain11, 0.0, 0.0, 0.0],
                             max_iter::Integer=50, norm_acc::Real=1e-9)
    function update_dstrain!(dstrain::V, dstress::V, jacobian::AbstractArray{T}) where V <: AbstractVector{T} where T <: Real
        dstrain_correction = -jacobian[2:end,2:end] \ dstress[2:end]
        dstrain[2:end] .+= dstrain_correction
        return norm(dstrain_correction)
    end
    find_dstrain!(material, dstrain, dt, update_dstrain!, max_iter=max_iter, tol=norm_acc)
    return nothing
end

"""
    biaxial_increment!(material::AbstractMaterial, dstrain11::Real, dstrain12::Real, dt::Real;
                       dstrain::AbstractVector{<:Real}=[dstrain11, -0.3*dstrain11, -0.3*dstrain11, 0, 0, dstrain12],
                       max_iter::Integer=50, norm_acc::Real=1e-9)

Find a compatible strain increment for `material`.

The material state (`material.variables`) and the components 11 and 12 of the
*strain* increment are taken as prescribed. This routine computes the other
components of the strain increment such that the predicted stress state matches
the stored one.

See `find_dstrain!`.
"""
function biaxial_increment!(material::AbstractMaterial, dstrain11::Real, dstrain12::Real, dt::Real;
                            dstrain::AbstractVector{<:Real}=[dstrain11, -0.3*dstrain11, -0.3*dstrain11, 0, 0, dstrain12],
                            max_iter::Integer=50, norm_acc::Real=1e-9)
    function update_dstrain!(dstrain::V, dstress::V, jacobian::AbstractArray{T}) where V <: AbstractVector{T} where T <: Real
        dstrain_correction = -jacobian[2:end-1,2:end-1] \ dstress[2:end-1]
        dstrain[2:end-1] .+= dstrain_correction
        return norm(dstrain_correction)
    end
    find_dstrain!(material, dstrain, dt, update_dstrain!, max_iter=max_iter, tol=norm_acc)
    return nothing
end

"""
    stress_driven_uniaxial_increment!(material::AbstractMaterial, dstress11::Real, dt::Real;
                                      dstrain::AbstractVector{<:Real}=[dstress11/200e3, -0.3*dstress11/200e3, -0.3*dstress11/200e3, 0.0, 0.0, 0.0],
                                      max_iter::Integer=50, norm_acc::Real=1e-9)

Find a compatible strain increment for `material`.

The material state (`material.variables`) and the component 11 of the *stress*
increment are taken as prescribed. This routine computes a strain increment such
that the predicted stress state matches the stored one.

See `find_dstrain!`.
"""
function stress_driven_uniaxial_increment!(material::AbstractMaterial, dstress11::Real, dt::Real;
                                           dstrain::AbstractVector{<:Real}=[dstress11/200e3, -0.3*dstress11/200e3, -0.3*dstress11/200e3, 0.0, 0.0, 0.0],
                                           max_iter::Integer=50, norm_acc::Real=1e-9)
    function update_dstrain!(dstrain::V, dstress::V, jacobian::AbstractArray{T}) where V <: AbstractVector{T} where T <: Real
        # Mutation of `dstress` doesn't matter, since `dstress` is freshly generated at each iteration.
        # The lexical closure property gives us access to `dstress11` in this scope.
        dstress[1] -= dstress11
        dstrain_correction = -jacobian \ dstress
        dstrain .+= dstrain_correction
        return norm(dstrain_correction)
    end
    find_dstrain!(material, dstrain, dt, update_dstrain!, max_iter=max_iter, tol=norm_acc)
    return nothing
end

end