"""
Every [entry point of error analysis](@ref jetanalysis-entry) can accept
any of [general JET configurations](@ref JET-configurations) as well as
the following additional configurations that are specific to the error analysis.

---
- `mode::Symbol = :basic`:\\
  Switches the error analysis pass. Each analysis pass reports errors according to their
  own "error" definition.
  JET by default offers the following modes:
  - `mode = :basic`: the default error analysis pass.
    This analysis pass is tuned to be useful for general Julia development by reporting common
    problems, but also note that it is not enough strict to guarantee that your program never
    throws runtime errors.\\
    See [`BasicPass`](@ref) for more details.
  - `mode = :sound`: the sound error analysis pass.
    If this pass doesn't report any errors, then your program is assured to run without
    any runtime errors (unless JET's error definition is not accurate and/or there is an
    implementation flaw).\\
    See [`SoundPass`](@ref) for more details.
  - `mode = :typo`: a typo detection pass
    A simple analysis pass to detect "typo"s in your program.
    This analysis pass is essentially a subset of the default basic pass ([`BasicPass`](@ref)),
    and it only reports undefined global reference and undefined field access.
    This might be useful especially for a very complex code base, because even the basic pass
    tends to be too noisy (spammed with too many errors) for such a case.\\
    See [`TypoPass`](@ref) for more details.

  !!! note
      You can also set up your own analysis using JET's [`AbstractAnalyzer`-Framework](@ref).
---
"""
struct JETAnalyzer{RP<:ReportPass} <: AbstractAnalyzer
    report_pass::RP
    state::AnalyzerState
    __cache_key::UInt
    method_table::CachedMethodTable
end

CC.may_optimize(::JETAnalyzer) = false

@static if VERSION ≥ v"1.10.0-DEV.25"
    CC.typeinf_lattice(::JETAnalyzer) = CC.InferenceLattice(CC.MustAliasesLattice(CC.BaseInferenceLattice.instance))
    CC.ipo_lattice(::JETAnalyzer) = CC.InferenceLattice(CC.InterMustAliasesLattice(CC.IPOResultLattice.instance))
end

# AbstractAnalyzer API
# ====================

# NOTE `@constprop :aggressive` here makes sure `mode` to be propagated as constant
@constprop :aggressive @jetconfigurable function JETAnalyzer(;
    report_pass::Union{Nothing,ReportPass} = nothing,
    mode::Symbol                           = :basic,
    # default `InferenceParams` tuning
    aggressive_constant_propagation::Bool = true,
    unoptimize_throw_blocks::Bool         = false,
    # default `OptimizationParams` tuning
    inlining::Bool = false,
    jetconfigs...)
    if isnothing(report_pass)
        # if `report_pass` isn't passed explicitly, here we configure it according to `mode`
        if mode === :basic
            report_pass = BasicPass(; jetconfigs...)
        elseif mode === :sound
            report_pass = SoundPass()
        elseif mode === :typo
            report_pass = TypoPass()
        else
            throw(ArgumentError("`mode` configuration should be either of `:basic`, `:sound` or `:typo`"))
        end
    elseif mode !== :basic
        throw(ArgumentError("either of `report_pass` and `mode` configurations can be specified"))
    end
    # NOTE we always disable inlining, because:
    # - our current strategy to find undefined local variables and uncaught `throw` calls assumes un-inlined frames
    # - the cost for inlining isn't necessary for JETAnalyzer
    inlining && throw(ArgumentError("inlining should be disabled for `JETAnalyzer`"))
    state = AnalyzerState(; aggressive_constant_propagation,
                            unoptimize_throw_blocks,
                            inlining,
                            jetconfigs...)
    cache_key = state.param_key
    cache_key = hash(report_pass, cache_key)
    world = CC.get_world_counter(state.native)
    method_table = CachedMethodTable(OverlayMethodTable(world, JET_METHOD_TABLE))
    analyzer = JETAnalyzer(report_pass, state, cache_key, method_table)
    return analyzer
end
JETInterface.AnalyzerState(analyzer::JETAnalyzer) = analyzer.state
function JETInterface.AbstractAnalyzer(analyzer::JETAnalyzer, state::AnalyzerState)
    report_pass = ReportPass(analyzer)
    cache_key = analyzer.__cache_key
    world = CC.get_world_counter(state.native)
    method_table = CachedMethodTable(OverlayMethodTable(world, JET_METHOD_TABLE))
    return JETAnalyzer(report_pass, state, cache_key, method_table)
end
JETInterface.ReportPass(analyzer::JETAnalyzer) = analyzer.report_pass
JETInterface.get_cache_key(analyzer::JETAnalyzer) = analyzer.__cache_key

"""
The basic (default) error analysis pass.

_**TODO**_: elaborate the definitions of "error"s.
"""
struct BasicPass{FF} <: ReportPass
    function_filter::FF
end
function BasicPass(;
    function_filter = jetanalyzer_function_filter,
    __jetconfigs...)
    return BasicPass(function_filter)
end

function jetanalyzer_function_filter(@nospecialize ft)
    ft === typeof(Base.mapreduce_empty) && return false
    ft === typeof(Base.reduce_empty) && return false
    return true
end

"""
The sound error analysis pass.

_**TODO**_: elaborate the definitions of "error"s.
"""
struct SoundPass <: ReportPass end

basic_filter(analyzer::JETAnalyzer, sv) =
    is_compileable_frame(sv) || get_entry(analyzer) === get_linfo(sv) # `report_call` may start analysis with abstract signature

# `SoundPass` is still WIP, we may use it to implement both passes at once for the meantime
const SoundBasicPass = Union{SoundPass,BasicPass}

"""
A typo detection pass.

_**TODO**_: elaborate the definitions of "error"s.
"""
struct TypoPass <: ReportPass end
(::TypoPass)(@nospecialize _...) = return false # ignore everything except GlobalUndefVarErrorReport and field error report

# overlay method table
# ====================

"""
    JET_METHOD_TABLE

This JET-specific method table keeps method definition overrides, that allow us to cut off
false positive errors, while simulating the original semantics reasonably.
This works as a temporal patch, and ideally we want to port it back to the Julia base or
a package, or improve the accuracy of base abstract interpretation analysis.
"""
@MethodTable JET_METHOD_TABLE
CC.method_table(analyzer::JETAnalyzer) = analyzer.method_table

# https://github.com/aviatesk/JET.jl/issues/404
# this definition makes it impossible to dispatch to `Base.iterate(()::Tuple, i::Int)`,
# getting rid of the false positive error from `getindex((), i)`.
@overlay JET_METHOD_TABLE Base.iterate(::Tuple{}, ::Int) = nothing

# overloads
# =========

function CC.InferenceState(result::InferenceResult, cache::Symbol, analyzer::JETAnalyzer)
    frame = @invoke CC.InferenceState(result::InferenceResult, cache::Symbol, analyzer::AbstractAnalyzer)
    if isnothing(frame) # indicates something bad happened within `retrieve_code_info`
        ReportPass(analyzer)(GeneratorErrorReport, analyzer, result)
    end
    return frame
end

function CC.finish!(analyzer::JETAnalyzer, frame::InferenceState)
    src = @invoke CC.finish!(analyzer::AbstractAnalyzer, frame::InferenceState)

    if isnothing(src)
        # caught in cycle, similar error should have been reported where the source is available
        return src
    else
        code = (src::CodeInfo).code
        # report pass for uncaught `throw` calls
        ReportPass(analyzer)(UncaughtExceptionReport, analyzer, frame, code)
        return src
    end
end

let # overload `abstract_call_gf_by_type`
    @static if @isdefined(StmtInfo)
        sigs_ex = :(analyzer::JETAnalyzer,
            @nospecialize(f), arginfo::ArgInfo, si::StmtInfo, @nospecialize(atype), sv::InferenceState,
            $(Expr(:kw, :(max_methods::Int), :(InferenceParams(analyzer).MAX_METHODS))))
        args_ex = :(analyzer::AbstractAnalyzer, f::Any, arginfo::ArgInfo, si::StmtInfo, atype::Any,
            sv::InferenceState, max_methods::Int)
        argtypes_ex = :(arginfo.argtypes)
    else
        sigs_ex = :(analyzer::JETAnalyzer,
            @nospecialize(f), arginfo::ArgInfo, @nospecialize(atype), sv::InferenceState,
            $(Expr(:kw, :(max_methods::Int), :(InferenceParams(analyzer).MAX_METHODS))))
        args_ex = :(analyzer::AbstractAnalyzer, f::Any, arginfo::ArgInfo, atype::Any,
            sv::InferenceState, max_methods::Int)
        argtypes_ex = :(arginfo.argtypes)
    end
    @eval function CC.abstract_call_gf_by_type($(sigs_ex.args...))
        ret = @invoke CC.abstract_call_gf_by_type($(args_ex.args...))
        ReportPass(analyzer)(MethodErrorReport, analyzer, sv, ret, $argtypes_ex, atype)
        ReportPass(analyzer)(UnanalyzedCallReport, analyzer, sv, ret, atype)
        return ret
    end
end

@doc """
    bail_out_call(analyzer::JETAnalyzer, ...)

With this overload, `abstract_call_gf_by_type(analyzer::JETAnalyzer, ...)` doesn't bail
out inference even after the current return type grows up to `Any` and collects as much
error points as possible.
Of course this slows down inference performance, but hoopefully it stays to be "practical"
speed since the number of matching methods are limited beforehand.
"""
CC.bail_out_call(analyzer::JETAnalyzer, @nospecialize(t), sv::InferenceState) = false

@doc """
    add_call_backedges!(analyzer::JETAnalyzer, ...)

An overload for `abstract_call_gf_by_type(analyzer::JETAnalyzer, ...)`, which always add
backedges (even if a new method can't refine the return type grew up to `Any`).
This is because a new method definition always has a potential to change `JETAnalyzer`'s analysis result.
"""
function CC.add_call_backedges!(analyzer::JETAnalyzer,
    @nospecialize(rettype), edges::Vector{MethodInstance},
    matches::Union{MethodMatches,UnionSplitMethodMatches}, @nospecialize(atype),
    sv::InferenceState)
    return @invoke CC.add_call_backedges!(analyzer::AbstractInterpreter,
        # NOTE this `__DummyAny__` hack forces `add_call_backedges!(::AbstractInterpreter,...)` to add backedges
        __DummyAny__::Any, edges::Vector{MethodInstance},
        matches::Union{MethodMatches,UnionSplitMethodMatches}, atype::Any,
        sv::InferenceState)
end

function CC.add_call_backedges!(analyzer::JETAnalyzer,
    @nospecialize(rettype), effects::CC.Effects,
    edges::Vector{MethodInstance}, matches::Union{MethodMatches,UnionSplitMethodMatches}, @nospecialize(atype),
    sv::InferenceState)
    return @invoke CC.add_call_backedges!(analyzer::AbstractInterpreter,
        # NOTE this `__DummyAny__` hack forces `add_call_backedges!(::AbstractInterpreter,...)` to add backedges
        __DummyAny__::Any, effects::CC.Effects,
        edges::Vector{MethodInstance}, matches::Union{MethodMatches,UnionSplitMethodMatches}, atype::Any,
        sv::InferenceState)
end
struct __DummyAny__ end

let # overload `const_prop_entry_heuristic`
    @static if @isdefined(StmtInfo)
        sigs_ex = :(::JETAnalyzer, result::MethodCallResult, si::StmtInfo, sv::InferenceState)
    else
        sigs_ex = :(::JETAnalyzer, result::MethodCallResult, sv::InferenceState)
    end
    @eval begin
        @doc """
            const_prop_entry_heuristic(analyzer::JETAnalyzer, result::MethodCallResult, sv::InferenceState)

        This overload for `abstract_call_method_with_const_args(analyzer::JETAnalyzer, ...)` forces
        constant prop' even if an inference result can't be improved anymore _with respect to the
        return type_, e.g. when `result.rt` is already `Const`.
        Especially, this overload implements an heuristic to force constant prop' when any error points
        have been reported while the previous abstract method call without constant arguments.
        The reason we want much more aggressive constant propagation by that heuristic is that it's
        highly possible constant prop' can produce more accurate analysis result, by throwing away
        false positive error reports by cutting off the unreachable control flow or detecting
        must-reachable `throw` calls.
        """
        CC.const_prop_entry_heuristic($(sigs_ex.args...)) = true
    end
end

let # overload `concrete_eval_eligible`
    @static if @isdefined(StmtInfo)
        # https://github.com/JuliaLang/julia/pull/46966
        sigs_ex = :(analyzer::JETAnalyzer,
            @nospecialize(f), result::MethodCallResult, arginfo::ArgInfo)
    else
        sigs_ex = :(analyzer::JETAnalyzer,
            @nospecialize(f), result::MethodCallResult, arginfo::ArgInfo, sv::InferenceState)
    end
    # TODO correctly reasons about error found by [semi-]concrete evaluation
    # for now just always fallback to the constant-prop'
    @eval function CC.concrete_eval_eligible($(sigs_ex.args...))
        @static if isdefined(CC, :ir_abstract_constant_propagation)
            return nothing # disables both concrete evaluation and semi-concrete interpretation
        else
            return false # disables concrete evaluation
        end
    end
end

let # overload `return_type_tfunc`
    @static if @isdefined(StmtInfo)
        sigs_ex = :(analyzer::JETAnalyzer, argtypes::Argtypes, si::StmtInfo, sv::InferenceState)
        args_ex = :(analyzer::AbstractAnalyzer, argtypes::Argtypes, si::StmtInfo, sv::InferenceState)
    else
        sigs_ex = :(analyzer::JETAnalyzer, argtypes::Argtypes, sv::InferenceState)
        args_ex = :(analyzer::AbstractAnalyzer, argtypes::Argtypes, sv::InferenceState)
    end
    @eval function CC.return_type_tfunc($(sigs_ex.args...))
        # report pass for invalid `Core.Compiler.return_type` call
        ReportPass(analyzer)(InvalidReturnTypeCall, analyzer, sv, argtypes)
        return @invoke CC.return_type_tfunc($(args_ex.args...))
    end
end

let # overload `abstract_invoke`
    @static if @isdefined(StmtInfo)
        sigs_ex = :(analyzer::JETAnalyzer, arginfo::ArgInfo, si::StmtInfo, sv::InferenceState)
        args_ex = :(analyzer::AbstractAnalyzer, arginfo::ArgInfo, si::StmtInfo, sv::InferenceState)
        argtypes_ex = :(arginfo.argtypes)
    else
        sigs_ex = :(analyzer::JETAnalyzer, arginfo::ArgInfo, sv::InferenceState)
        args_ex = :(analyzer::AbstractAnalyzer, arginfo::ArgInfo, sv::InferenceState)
        argtypes_ex = :(arginfo.argtypes)
    end
    @eval function CC.abstract_invoke($(sigs_ex.args...))
        ret = @invoke CC.abstract_invoke($(args_ex.args...))
        if isa(ret, CallMeta)
            ReportPass(analyzer)(InvalidInvokeErrorReport, analyzer, sv, ret, $argtypes_ex)
        else # otherwise https://github.com/JuliaLang/julia/pull/44764 is active
            ReportPass(analyzer)(InvalidInvokeErrorReport, analyzer, sv, ret[1], $argtypes_ex)
        end
        return ret
    end
end

function CC.abstract_eval_special_value(analyzer::JETAnalyzer,
    @nospecialize(e), vtypes::VarTable, sv::InferenceState)
    ret = @invoke CC.abstract_eval_special_value(analyzer::AbstractAnalyzer,
        e::Any, vtypes::VarTable, sv::InferenceState)

    if isa(e, GlobalRef)
        mod, name = e.mod, e.name
        # report pass for undefined global reference
        ReportPass(analyzer)(GlobalUndefVarErrorReport, analyzer, sv, mod, name)

        # NOTE `NativeInterpreter` should return `ret = Any` `ret` even if `mod.name`
        # isn't defined and we just pass it as is to collect as much error points as possible
        # we can change it to `Bottom` to suppress any further inference with this variable,
        # but then we also need to make sure to invalidate the cache for the analysis on
        # the future re-definition of this (currently) undefined binding
        # return Bottom
    # TODO enable this
    # elseif isa(e, SlotNumber)
    #     # report pass for (local) undef var error
    #     ReportPass(analyzer)(LocalUndefVarErrorReport, analyzer, sv, e, vtypes, ret)
    end

    return ret
end

# N.B. this report pass won't be necessary as the frontend will generate code
# that `typeassert`s the value type as the binding type beforehand
@static if isdefined(CC, :abstract_eval_basic_statement)
@inline function CC.abstract_eval_basic_statement(analyzer::JETAnalyzer,
    @nospecialize(stmt), pc_vartable::VarTable, frame::InferenceState)
    ret = @invoke CC.abstract_eval_basic_statement(analyzer::AbstractAnalyzer,
        stmt::Any, pc_vartable::VarTable, frame::InferenceState)
    if isexpr(stmt, :(=)) && (lhs = stmt.args[1]; isa(lhs, GlobalRef))
        ReportPass(analyzer)(InvalidGlobalAssignmentError, analyzer,
            frame, lhs.mod, lhs.name, ret.type)
    end
    return ret
end
else # @static if isdefined(CC, :abstract_eval_basic_statement)
function CC.abstract_eval_statement(analyzer::JETAnalyzer,
    @nospecialize(e), vtypes::VarTable, sv::InferenceState)
    ret = @invoke CC.abstract_eval_statement(analyzer::AbstractAnalyzer,
        e::Any, vtypes::VarTable, sv::InferenceState)
    stmt = get_stmt((sv, get_currpc(sv)))
    if isexpr(stmt, :(=)) && (lhs = stmt.args[1]; isa(lhs, GlobalRef))
        ReportPass(analyzer)(InvalidGlobalAssignmentError, analyzer,
            sv, lhs.mod, lhs.name, ret)
    end
    return ret
end
end # @static if isdefined(CC, :abstract_eval_basic_statement)

function CC.abstract_eval_value(analyzer::JETAnalyzer, @nospecialize(e), vtypes::VarTable, sv::InferenceState)
    ret = @invoke CC.abstract_eval_value(analyzer::AbstractAnalyzer, e::Any, vtypes::VarTable, sv::InferenceState)

    # report non-boolean condition error
    stmt = get_stmt((sv, get_currpc(sv)))
    if isa(stmt, GotoIfNot)
        t = widenconst(ret)
        if t !== Bottom
            ReportPass(analyzer)(NonBooleanCondErrorReport, analyzer, sv, t)
            # if this condition leads to an "non-boolean (t) used in boolean context" error,
            # we can turn it into Bottom and bail out early
            # TODO upstream this ?
            if !hasintersect(t, Bool)
                ret = Bottom
            end
        end
    end

    return ret
end

function CC.builtin_tfunction(analyzer::JETAnalyzer,
    @nospecialize(f), argtypes::Array{Any,1}, sv::InferenceState) # `AbstractAnalyzer` isn't overloaded on `return_type`
    ret = @invoke CC.builtin_tfunction(analyzer::AbstractAnalyzer,
        f::Any, argtypes::Array{Any,1}, sv::InferenceState)

    if f === fieldtype
        # the valid widest possible return type of `fieldtype_tfunc` is `Union{Type,TypeVar}`
        # because fields of unwrapped `DataType`s can legally be `TypeVar`s,
        # but this will lead to lots of false positive `MethodErrorReport`s for inference
        # with accessing to abstract fields since most methods don't expect `TypeVar`
        # (e.g. `@report_call readuntil(stdin, 'c')`)
        # JET.jl further widens this case to `Any` and give up further analysis rather than
        # trying hard to do sound and noisy analysis
        # xref: https://github.com/JuliaLang/julia/pull/38148
        if ret === Union{Type, TypeVar}
            ret = Any
        end
    end

    if f === throw
        # here we only report a selection of "serious" exceptions, i.e. those that should be
        # reported even if they may be caught in actual execution;
        ReportPass(analyzer)(SeriousExceptionReport, analyzer, sv, argtypes)

        # other general `throw` calls will be handled within `_typeinf(analyzer::AbstractAnalyzer, frame::InferenceState)`
    else
        ReportPass(analyzer)(AbstractBuiltinErrorReport, analyzer, sv, f, argtypes, ret)
    end

    return ret
end

# analysis
# ========

@jetreport struct GeneratorErrorReport <: InferenceErrorReport
    @nospecialize err # actual error wrapped
end
function print_report_message(io::IO, (; err)::GeneratorErrorReport)
    showerror(io, err)
end

# XXX what's the "soundness" of a `@generated` function ?
# adapated from https://github.com/JuliaLang/julia/blob/f806df603489cfca558f6284d52a38f523b81881/base/compiler/utilities.jl#L107-L137
function (::SoundBasicPass)(::Type{GeneratorErrorReport}, analyzer::JETAnalyzer, result::InferenceResult)
    mi = result.linfo
    m = mi.def::Method
    if isdefined(m, :generator)
        # analyze_method_instance!(analyzer, linfo) XXX doesn't work
        may_invoke_generator(mi) || return false
        try
            ccall(:jl_code_for_staged, Any, (Any,), mi) # invoke the "errorneous" generator again
        catch err
            # if user code throws error, wrap and report it
            report = add_new_report!(analyzer, result, GeneratorErrorReport(mi, err))
            # we will return back to the caller immediately
            add_caller_cache!(analyzer, report)
            return true
        end
    end
    return false
end

"""
    UncaughtExceptionReport <: InferenceErrorReport

Represents general `throw` calls traced during inference.
This is reported only when it's not caught by control flow.
"""
@jetreport struct UncaughtExceptionReport <: InferenceErrorReport
    throw_calls::Vector{Tuple{Int,Expr}} # (pc, call)
end
function UncaughtExceptionReport(sv::InferenceState, throw_calls::Vector{Tuple{Int,Expr}})
    vf = get_virtual_frame(sv.linfo)
    sig = Any[]
    ncalls = length(throw_calls)
    for (i, (pc, call)) in enumerate(throw_calls)
        call_sig = get_sig_nowrap((sv, pc), call)
        append!(sig, call_sig)
        i ≠ ncalls && push!(sig, ", ")
    end
    return UncaughtExceptionReport([vf], Signature(sig), throw_calls)
end
function print_report_message(io::IO, (; throw_calls)::UncaughtExceptionReport)
    msg = length(throw_calls) == 1 ? "may throw" : "may throw either of"
    print(io, msg)
end

# report `throw` calls "appropriately"
# this error report pass is very special, since 1.) it's tightly bound to the report pass of
# `SeriousExceptionReport` and 2.) it involves "report filtering" on its own
function (::BasicPass)(::Type{UncaughtExceptionReport}, analyzer::JETAnalyzer, frame::InferenceState, stmts::Vector{Any})
    if frame.bestguess === Bottom
        report_uncaught_exceptions!(analyzer, frame, stmts)
        return true
    else
        # the non-`Bottom` result may mean `throw` calls from the children frames
        # (if exists) are caught and not propagated here
        # we don't want to cache the caught `UncaughtExceptionReport`s for this frame and
        # its parents, and just filter them away now
        filter!(report->!isa(report, UncaughtExceptionReport), get_reports(analyzer, frame.result))
    end
    return false
end
(::SoundPass)(::Type{UncaughtExceptionReport}, analyzer::JETAnalyzer, frame::InferenceState, stmts::Vector{Any}) =
    report_uncaught_exceptions!(analyzer, frame, stmts) # yes, you want tons of false positives !
function report_uncaught_exceptions!(analyzer::JETAnalyzer, frame::InferenceState, stmts::Vector{Any})
    # if the return type here is `Bottom` annotated, this _may_ mean there're uncaught
    # `throw` calls
    # XXX it's possible that the `throw` calls within them are all caught but the other
    # critical errors still make the return type `Bottom`
    # NOTE to reduce the false positive cases described above, we count `throw` calls
    # after optimization, since it may have eliminated "unreachable" `throw` calls
    codelocs = frame.src.codelocs
    linetable = frame.src.linetable::LineTable
    reported_locs = nothing
    for report in get_reports(analyzer, frame.result)
        if isa(report, SeriousExceptionReport)
            if isnothing(reported_locs)
                reported_locs = LineInfoNode[]
            end
            push!(reported_locs, report.loc)
        end
    end
    throw_calls = nothing
    for (pc, stmt) in enumerate(stmts)
        isa(stmt, Expr) || continue
        is_throw_call(stmt) || continue
        # if this `throw` is already reported, don't duplciate
        if !isnothing(reported_locs) && linetable[codelocs[pc]]::LineInfoNode in reported_locs
            continue
        end
        if isnothing(throw_calls)
            throw_calls = Tuple{Int,Expr}[]
        end
        push!(throw_calls, (pc, stmt))
    end
    if !isnothing(throw_calls) && !isempty(throw_calls)
        add_new_report!(analyzer, frame.result, UncaughtExceptionReport(frame, throw_calls))
        return true
    end
    return false
end

@jetreport struct MethodErrorReport <: InferenceErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
    uncovered::Bool
end
function print_report_message(io::IO, report::MethodErrorReport)
    (; t, union_split, uncovered) = report
    if uncovered
        print(io, "uncovered method match found ")
    else
        print(io, "no matching method found ")
    end
    if union_split == 0
        print_callsig(io, t)
    else
        ts = t::Vector{Any}
        nts = length(ts)
        for i = 1:nts
            print_callsig(io, ts[i])
            i == nts || print(io, ", ")
        end
        print(io, " (", nts, '/', union_split, " union split)")
    end
end
function print_callsig(io, @nospecialize(t))
    print(io, '`')
    Base.show_tuple_as_call(io, Symbol(""), t)
    print(io, '`')
end

function (rp::BasicPass)(::Type{MethodErrorReport}, analyzer::JETAnalyzer,
    sv::InferenceState, call::CallMeta, argtypes::Argtypes, @nospecialize(atype))
    info = call.info
    if isa(info, ConstCallInfo)
        info = info.call
    end
    if isa(info, MethodMatchInfo) || isa(info, UnionSplitInfo)
        basic_filter(analyzer, sv) || return false
        ft = widenconst(first(argtypes))
        rp.function_filter(ft) || return false
    end
    if isa(info, MethodMatchInfo)
        return report_method_error!(analyzer, sv, info, atype, call.rt, #=sound=#false)
    elseif isa(info, UnionSplitInfo)
        return report_method_error_for_union_split!(analyzer, sv, info, argtypes, call.rt, #=sound=#false)
    end
    return false
end

function (::SoundPass)(::Type{MethodErrorReport}, analyzer::JETAnalyzer,
    sv::InferenceState, call::CallMeta, argtypes::Argtypes, @nospecialize(atype))
    (; rt, info) = call
    if isa(info, ConstCallInfo)
        info = info.call
    end
    if isa(info, MethodMatchInfo)
        return report_method_error!(analyzer, sv, info, atype, rt, #=sound=#true)
    elseif isa(info, UnionSplitInfo)
        return report_method_error_for_union_split!(analyzer, sv, info, argtypes, rt, #=sound=#true)
    end
    return false
end

function report_method_error!(analyzer::JETAnalyzer,
    sv::InferenceState, info::MethodMatchInfo, @nospecialize(atype), @nospecialize(rt), sound::Bool)
    if is_empty_match(info)
        add_new_report!(analyzer, sv.result, MethodErrorReport(sv, atype, 0, #=uncovered=#false))
        return true
    elseif sound && !is_fully_covered(info)
        report = MethodErrorReport(sv, atype, 0, #=uncovered=#true)
        report.sig[end] = widenconst(ignorelimited(rt))
        add_new_report!(analyzer, sv.result, report)
        return true
    end
    return false
end

function report_method_error_for_union_split!(analyzer::JETAnalyzer,
    sv::InferenceState, info::UnionSplitInfo, argtypes::Argtypes, @nospecialize(rt), sound::Bool)
    # check each match for union-split signature
    split_argtypes = nothing
    empty_matches = uncovered_matches = nothing
    for (i, matchinfo) in enumerate(info.matches)
        if is_empty_match(matchinfo)
            isnothing(split_argtypes) && (split_argtypes = switchtupleunion(argtypes))
            if empty_matches === nothing
                empty_matches = (Any[], length(info.matches))
            end
            sig_n = argtypes_to_type(split_argtypes[i]::Vector{Any})
            push!(empty_matches[1], sig_n)
        elseif sound && !is_fully_covered(matchinfo)
            isnothing(split_argtypes) && (split_argtypes = switchtupleunion(argtypes))
            if uncovered_matches === nothing
                uncovered_matches = (Any[], length(info.matches))
            end
            sig_n = argtypes_to_type(split_argtypes[i]::Vector{Any})
            push!(uncovered_matches[1], sig_n)
        end
    end
    reported = false
    if empty_matches !== nothing
        add_new_report!(analyzer, sv.result, MethodErrorReport(sv, empty_matches..., #=reason=#false))
        reported |= true
    end
    if uncovered_matches !== nothing
        report = MethodErrorReport(sv, uncovered_matches..., #=uncovered=#true)
        add_new_report!(analyzer, sv.result, report)
        report.sig[end] = widenconst(ignorelimited(rt))
        reported |= true
    end
    return reported
end

is_empty_match(info::MethodMatchInfo) = CC.isempty(info.results)
is_fully_covered(info::MethodMatchInfo) = CC._all(m->m.fully_covers, info.results)

@jetreport struct UnanalyzedCallReport <: InferenceErrorReport
    @nospecialize type
end
function print_report_message(io::IO, report::UnanalyzedCallReport)
    print(io, "unanalyzed method call ")
    print_callsig(io, report.type)
end

(::BasicPass)(::Type{UnanalyzedCallReport}, ::JETAnalyzer, ::InferenceState, ::CallMeta, @nospecialize(_)) = false
(::TypoPass)(::Type{UnanalyzedCallReport}, ::JETAnalyzer, ::InferenceState, ::CallMeta, @nospecialize(_)) = false
function (::SoundPass)(::Type{UnanalyzedCallReport}, analyzer::JETAnalyzer,
    sv::InferenceState, call::CallMeta, @nospecialize(atype))
    if call.info === false
        @assert call.rt === Any "unexpected call info"
        report = UnanalyzedCallReport(sv, atype)
        add_new_report!(analyzer, sv.result, report)
        report.sig[end] = Any
        return true
    end
    return false
end

@jetreport struct InvalidReturnTypeCall <: InferenceErrorReport end
function print_report_message(io::IO, ::InvalidReturnTypeCall)
    print(io, "invalid `Core.Compiler.return_type` call")
end

function (::SoundBasicPass)(::Type{InvalidReturnTypeCall}, analyzer::AbstractAnalyzer, sv::InferenceState, argtypes::Argtypes)
    # here we make a very simple analysis to check if the call of `return_type` is clearly
    # invalid or not by just checking the # of call arguments
    # we don't take a (very unexpected) possibility of its overload into account here,
    # `NativeInterpreter` doens't also (it hard-codes the return type as `Type`)
    if length(argtypes) ≠ 3
        # invalid argument #, let's report and return error result (i.e. `Bottom`)
        add_new_report!(analyzer, sv.result, InvalidReturnTypeCall(sv))
        return true
    end
    return false
end

@jetreport struct InvalidInvokeErrorReport <: InferenceErrorReport
    argtypes::Argtypes
end
function print_report_message(io::IO, (; argtypes)::InvalidInvokeErrorReport)
    fallback_msg = "invalid invoke" # mostly because of runtime unreachable

    ft = widenconst(argtype_by_index(argtypes, 2))
    if ft === Bottom
        print(io, "invalid invoke") # mostly because of runtime unreachable
        return
    end

    t = argtype_by_index(argtypes, 3)
    (types, isexact, isconcrete, istype) = instanceof_tfunc(t)
    if types === Bottom
        if isa(t, Const)
            type = typeof(t.val)
            print(io, "argument type should be `Type`-object (given `", type, "`)")
        else
            print(io, "invalid invoke") # mostly because of runtime unreachable
        end
        return
    end

    argtype = argtypes_to_type(argtype_tail(argtypes, 4))
    nargtype = typeintersect(types, argtype)
    @assert nargtype === Bottom
    print(io, "actual argument type `", argtype, "` doesn't intersect with specified argument type `", types, '`')
    return
end

function (::SoundBasicPass)(::Type{InvalidInvokeErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, ret::CallMeta, argtypes::Argtypes)
    if ret.rt === Bottom
        # here we report error that happens at the call of `invoke` itself.
        # if the error type (`Bottom`) is propagated from the `invoke`d call, the error has
        # already been reported within `typeinf_edge`, so ignore that case
        if !isa(ret.info, InvokeCallInfo)
            add_new_report!(analyzer, sv.result, InvalidInvokeErrorReport(sv, argtypes))
            return true
        end
    end
    return false
end

@jetreport struct GlobalUndefVarErrorReport <: InferenceErrorReport
    mod::Module
    name::Symbol
end
function print_report_message(io::IO, (; mod, name)::GlobalUndefVarErrorReport)
    print(io, "`", mod, '.', name, "` is not defined")
end
print_signature(::GlobalUndefVarErrorReport) = false

(::SoundPass)(::Type{GlobalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, mod::Module, name::Symbol) =
    report_undef_var!(analyzer, sv, mod, name, #=sound=#true)
(::BasicPass)(::Type{GlobalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, mod::Module, name::Symbol) =
    report_undef_var!(analyzer, sv, mod, name, #=sound=#false)
(::TypoPass)(::Type{GlobalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, mod::Module, name::Symbol) =
    report_undef_var!(analyzer, sv, mod, name, #=sound=#false)
function report_undef_var!(analyzer::JETAnalyzer, sv::InferenceState, mod::Module, name::Symbol, sound::Bool)
    if !isdefined(mod, name)
        report = false
        if sound
            report |= true
        else
            if is_corecompiler_undefglobal(mod, name)
            elseif VERSION ≥ v"1.8.0-DEV.1465" && ccall(:jl_binding_type, Any, (Any, Any), mod, name) !== nothing
                # if this global var is explicitly type-declared, it will be likely get assigned somewhere
                # TODO give this permission only to top-level analysis
            else
                report |= true
            end
        end
        if report
            add_new_report!(analyzer, sv.result, GlobalUndefVarErrorReport(sv, mod, name))
            return true
        end
    end
    return false
end

# Returns `true` if this global reference is undefined inside `Core.Compiler`, but the
# corresponding name exists in the `Base` module.
# `Core.Compiler` reuses the minimum amount of `Base` code and there're some of missing
# definitions, and `BasicPass` will exclude reports on those undefined names since they
# usually don't matter and `Core.Compiler`'s basic functionality is battle-tested and
# validated exhausively by its test suite and real-world usages.
function is_corecompiler_undefglobal(mod::Module, name::Symbol)
    mod === CC && return isdefined(Base, name)
    @static if isdefined(CC, :Sort)
        mod === CC.Sort && return isdefined(Base.Sort, name)
    end
    return false
end

@jetreport struct LocalUndefVarErrorReport <: InferenceErrorReport
    name::Symbol
end
print_report_message(io::IO, (; name)::LocalUndefVarErrorReport) =
    print(io, "local variable $name is not defined")
print_signature(::LocalUndefVarErrorReport) = false

# these report passes use `:throw_undef_if_not` and `:(unreachable)` introduced by the native
# optimization pass, and thus supposed to only work on post-optimization code
# (::SoundPass)(::Type{LocalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, e::SlotNumber, vtypes::VarTable, @nospecialize(ret)) =
#     report_undefined_local_slots!(analyzer, sv, e, vtypes, ret, #=unsound=#false)
# (::BasicPass)(::Type{LocalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, e::SlotNumber, vtypes::VarTable, @nospecialize(ret)) =
#     report_undefined_local_slots!(analyzer, sv, e, vtypes, ret, #=unsound=#true)

function (::SoundPass)(::Type{LocalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState,
    var::SlotNumber, vtypes::VarTable, @nospecialize(ret))
    vtyp = vtypes[slot_id(var)]
    if vtyp.undef
        add_new_report!(analyzer, sv.result, LocalUndefVarErrorReport(sv, get_slotname(sv, var)))
        return true
    end
    return false
end
function (::BasicPass)(::Type{LocalUndefVarErrorReport}, analyzer::JETAnalyzer, sv::InferenceState,
    var::SlotNumber, vtypes::VarTable, @nospecialize(ret))
    ret === Bottom || return false
    add_new_report!(analyzer, sv.result, LocalUndefVarErrorReport(sv, get_slotname(sv, var)))
    return true
end

@jetreport struct InvalidGlobalAssignmentError <: InferenceErrorReport
    @nospecialize vtyp
    @nospecialize btyp
    mod::Module
    name::Symbol
end
function print_report_message(io::IO, report::InvalidGlobalAssignmentError)
    print(io, "found invalid assignment of an incompatible value")
    print(io, " (`", report.vtyp, "`)")
    print(io, " to the value global")
    print(io, " `", GlobalRef(report.mod, report.name), "`")
    print(io, " (`", report.btyp, "`)")
end

(::SoundPass)(::Type{InvalidGlobalAssignmentError}, analyzer::JETAnalyzer,
    sv::InferenceState, mod::Module, name::Symbol, @nospecialize(vtyp)) =
    report_global_assignment!(analyzer, sv, mod, name, vtyp,#=sound=#true)
(::BasicPass)(::Type{InvalidGlobalAssignmentError}, analyzer::JETAnalyzer,
    sv::InferenceState, mod::Module, name::Symbol, @nospecialize(vtyp)) =
    report_global_assignment!(analyzer, sv, mod, name, vtyp,#=sound=#false)
(::TypoPass)(::Type{InvalidGlobalAssignmentError}, analyzer::JETAnalyzer,
    sv::InferenceState, mod::Module, name::Symbol, @nospecialize(vtyp)) =
    report_global_assignment!(analyzer, sv, mod, name, vtyp, #=sound=#false)
function report_global_assignment!(analyzer::JETAnalyzer,
    sv::InferenceState, mod::Module, name::Symbol, @nospecialize(vtyp), sound::Bool)
    btyp = ccall(:jl_binding_type, Any, (Any, Any), mod, name)
    if btyp !== nothing
        vtyp = widenconst(vtyp)
        if !(sound ? vtyp ⊑ btyp : hasintersect(vtyp, btyp))
            add_new_report!(analyzer, sv.result, InvalidGlobalAssignmentError(sv, vtyp, btyp, mod, name))
            return true
        end
        return false
    else # the binding type hasn't been declared yet
        return false
    end
end

@jetreport struct NonBooleanCondErrorReport <: InferenceErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
    uncovered::Bool
end
function print_report_message(io::IO, report::NonBooleanCondErrorReport)
    (; t, union_split, uncovered) = report
    if union_split == 0
        print(io, "non-boolean `", t, "`")
        if uncovered
            print(io, " may be used in boolean context")
        else
            print(io, " found in boolean context")
        end
    else
        ts = t::Vector{Any}
        nts = length(ts)
        print(io, "non-boolean ")
        for i = 1:nts
            print(io, '`', ts[i], '`')
            i == nts || print(io, ", ")
        end
        if uncovered
            print(io, " may be used in boolean context")
        else
            print(io, " found in boolean context")
        end
        print(io, " (", nts, '/', union_split, " union split)")
    end
end

function (::SoundPass)(::Type{NonBooleanCondErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(t))
    return report_non_boolean_cond!(analyzer, sv, t, #=sound=#true)
end

function (::BasicPass)(::Type{NonBooleanCondErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(t))
    return basic_filter(analyzer, sv) && report_non_boolean_cond!(analyzer, sv, t, #=sound=#false)
end

function report_non_boolean_cond!(analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(t),
    check_uncovered::Bool)
    if isa(t, Union)
        info = nothing
        uts = Base.uniontypes(t)
        for t in uts
            if !(check_uncovered ? t ⊑ Bool : hasintersect(t, Bool))
                if info === nothing
                    info = Any[], length(uts)
                end
                push!(info[1], t)
            end
        end
        if info !== nothing
            add_new_report!(analyzer, sv.result, NonBooleanCondErrorReport(sv, info..., #=uncovered=#check_uncovered))
            return true
        end
    else
        if !(check_uncovered ? t ⊑ Bool : hasintersect(t, Bool))
            add_new_report!(analyzer, sv.result, NonBooleanCondErrorReport(sv, t, 0, #=uncovered=#check_uncovered))
            return true
        end
    end
    return false
end

function (::SoundBasicPass)(::Type{InvalidConstantRedefinition}, analyzer::JETAnalyzer, sv::InferenceState, mod::Module, name::Symbol, @nospecialize(prev_t), @nospecialize(t))
    add_new_report!(analyzer, sv.result, InvalidConstantRedefinition(sv, mod, name, prev_t, t))
    return true
end
function (::SoundBasicPass)(::Type{InvalidConstantDeclaration}, analyzer::JETAnalyzer, sv::InferenceState, mod::Module, name::Symbol)
    add_new_report!(analyzer, sv.result, InvalidConstantDeclaration(sv, mod, name))
    return true
end

# XXX tfunc implementations in Core.Compiler are really not enough to catch invalid calls
# TODO set up our own checks and enable sound analysis

"""
    SeriousExceptionReport <: InferenceErrorReport

Represents a "serious" error that is manually thrown by a `throw` call.
This is reported regardless of whether it's caught by control flow or not, as opposed to
[`UncaughtExceptionReport`](@ref).
"""
@jetreport struct SeriousExceptionReport <: InferenceErrorReport
    @nospecialize err
    # keeps the location where this exception is raised
    # this information will be used later when collecting `UncaughtExceptionReport`s
    # in order to avoid duplicated reports from the same `throw` call
    loc::LineInfoNode
end
function print_report_message(io::IO, (; err)::SeriousExceptionReport)
    s = with_bufferring(io->showerror(io, err))
    print(io, first(split(s, '\n')))
end

(::BasicPass)(::Type{SeriousExceptionReport}, analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes) =
    basic_filter(analyzer, sv) && report_serious_exception!(analyzer, sv, argtypes)
(::SoundPass)(::Type{SeriousExceptionReport}, analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes) =
    report_serious_exception!(analyzer, sv, argtypes) # any (non-serious) `throw` calls will be caught by the report pass for `UncaughtExceptionReport`
function report_serious_exception!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes)
    if length(argtypes) ≥ 1
        a = first(argtypes)
        if isa(a, Const)
            err = a.val
            if isa(err, UndefKeywordError)
                add_new_report!(analyzer, sv.result, SeriousExceptionReport(sv, err, get_lin((sv, get_currpc(sv)))))
                return true
            elseif isa(err, MethodError)
                # ignore https://github.com/JuliaLang/julia/blob/7409a1c007b7773544223f0e0a2d8aaee4a45172/base/boot.jl#L261
                if err.f !== Bottom
                    add_new_report!(analyzer, sv.result, SeriousExceptionReport(sv, err, get_lin((sv, get_currpc(sv)))))
                    return true
                end
            end
        end
    end
    return false
end

"""
    AbstractBuiltinErrorReport

Represents errors caused by builtin-function calls.
Technically they're defined as those error points that can be caught within `Core.Compiler.builtin_tfunction`.
"""
abstract type AbstractBuiltinErrorReport <: InferenceErrorReport end

# TODO: docs
@jetreport struct BuiltinErrorReport <: AbstractBuiltinErrorReport
    @nospecialize(f)
    argtypes::Argtypes
    msg::AbstractString
    print_signature::Bool = false
end
print_report_message(io::IO, r::BuiltinErrorReport) = print(io, r.msg)
print_signature(r::BuiltinErrorReport) = r.print_signature
const GENERAL_BUILTIN_ERROR_MSG = "invalid builtin function call"

# TODO we do need sound versions of these functions
# XXX for general case JET just relies on the (maybe too permissive) return type from native
# tfuncs to report invalid builtin calls and probably there're lots of false negatives

function (::BasicPass)(::Type{AbstractBuiltinErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(f), argtypes::Argtypes, @nospecialize(ret))
    @assert !(f === throw) "`throw` calls shuold be handled either by the report pass of `SeriousExceptionReport` or `UncaughtExceptionReport`"
    if f === getfield
        report_getfield!(analyzer, sv, argtypes, ret) && return true
    elseif f === setfield!
        report_setfield!!(analyzer, sv, argtypes, ret) && return true
    elseif f === fieldtype
        report_fieldtype!(analyzer, sv, argtypes, ret) && return true
    elseif @static @isdefined(getglobal) ? (f === getglobal) : false
        report_getglobal!(analyzer, sv, argtypes, ret) && return true
    elseif @static @isdefined(setglobal!) ? (f === setglobal!) : false
        report_setglobal!!(analyzer, sv, argtypes) && return true
    elseif length(argtypes) == 2 && is_division_func(f)
        report_devide_error!(analyzer, sv, f, argtypes) && return true
    end
    return handle_invalid_builtins!(analyzer, sv, f, argtypes, ret)
end

function (::TypoPass)(::Type{AbstractBuiltinErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(f), argtypes::Argtypes, @nospecialize(ret))
    if f === getfield
        report_getfield!(analyzer, sv, argtypes, ret) && return true
    elseif @static @isdefined(getglobal) ? (f === getglobal) : false
        report_getglobal!(analyzer, sv, argtypes, ret) && return true
    elseif @static @isdefined(setglobal!) ? (f === setglobal!) : false
        report_setglobal!!(analyzer, sv, argtypes) && return true
    end
    return false
end

function report_getfield!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes, @nospecialize(ret))
    if ret === Any
        report_getglobal!(analyzer, sv, argtypes) && return true
    elseif ret === Bottom
        report_fieldaccess!(analyzer, sv, getfield, argtypes) && return true
    end
    return false
end

report_getglobal!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes, @nospecialize(ret)) =
    ret === Any && report_getglobal!(analyzer, sv, argtypes)
function report_getglobal!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes)
    2 ≤ length(argtypes) ≤ 3 || return false
    gr = constant_globalref(argtypes)
    gr === nothing && return false
    # forward to the report pass for undefined global reference
    return ReportPass(analyzer)(GlobalUndefVarErrorReport, analyzer, sv, gr.mod, gr.name)
end

function report_setfield!!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes, @nospecialize(ret))
    if ret === Bottom
        report_fieldaccess!(analyzer, sv, setfield!, argtypes) && return true
    end
    return false
end

function report_fieldtype!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes, @nospecialize(ret))
    if ret === Bottom
        report_fieldaccess!(analyzer, sv, fieldtype, argtypes) && return true
    end
    return false
end

function report_setglobal!!(analyzer::JETAnalyzer, sv::InferenceState, argtypes::Argtypes)
    3 ≤ length(argtypes) ≤ 4 || return false
    gr = constant_globalref(argtypes)
    gr === nothing && return false
    # forward to the report pass for invalid global assignemt
    return ReportPass(analyzer)(InvalidGlobalAssignmentError, analyzer, sv, gr.mod, gr.name, argtypes[3])
end

# TODO use Core.Compiler version when ported
function _getfield_fieldindex(s::DataType, name::Const)
    nv = name.val
    if isa(nv, Symbol)
        nv = Base.fieldindex(s, nv, false)
    end
    if isa(nv, Int)
        return nv
    end
    return nothing
end

const MODULE_SETFIELD_MSG = "cannot assign variables in other modules"
const DEVIDE_ERROR_MSG = sprint(showerror, DivideError())
function type_error_msg(@nospecialize(f), @nospecialize(expected), @nospecialize(actual))
    return lazy"TypeError: in $f, expected $expected, got a value of type $actual"
end
function nofield_msg(@nospecialize(typ), name::Symbol)
    if typ <: Tuple
        typ = Tuple # reproduce base error message
    end
    return lazy"type $typ has no field $name"
end
function boundserror_msg(@nospecialize(typ), name::Int)
    return lazy"BoundsError: attempt to access $typ at index [$name]"
end

function report_fieldaccess!(analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(f), argtypes::Argtypes)
    2 ≤ length(argtypes) ≤ 3 || return false

    issetfield! = f === setfield!
    obj, name = argtypes[1], argtypes[2]
    s00 = widenconst(obj)

    if issetfield!
        if !_mutability_errorcheck(s00)
            msg = lazy"setfield!: immutable struct of type $s00 cannot be changed"
            report = BuiltinErrorReport(sv, setfield!, argtypes, msg)
            add_new_report!(analyzer, sv.result, report)
            return true
        end
    end

    isa(name, Const) || return false
    s = unwrap_unionall(s00)
    if isType(s)
        if f === fieldtype
            # XXX this is a hack to share more code between `getfield`/`setfield!`/`fieldtype`
            s00 = s = s.parameters[1]
        elseif isconstType(s)
            s = (s00::DataType).parameters[1]
        else
            return false
        end
    end
    isa(s, DataType) || return false
    isabstracttype(s) && return false
    if s <: Module
        if issetfield!
            report = BuiltinErrorReport(sv, setfield!, argtypes, MODULE_SETFIELD_MSG)
            add_new_report!(analyzer, sv.result, report)
            return true
        end
        nametyp = widenconst(name)
        if !hasintersect(nametyp, Symbol)
            msg = type_error_msg(getglobal, Symbol, nametyp)
            report = BuiltinErrorReport(sv, getglobal, argtypes, msg)
            add_new_report!(analyzer, sv.result, report)
            return true
        end
    end
    fidx = _getfield_fieldindex(s, name)
    fidx === Bottom && @goto report_nofield_error
    ftypes = Base.datatype_fieldtypes(s)
    nf = length(ftypes)
    (fidx < 1 || fidx > nf) && @goto report_nofield_error
    return false

    @label report_nofield_error
    namev = (name::Const).val
    objtyp = s00
    if namev isa Symbol
        msg = nofield_msg(objtyp, namev)
    elseif namev isa Int
        msg = boundserror_msg(objtyp, namev)
    else
        @assert false "invalid field analysis"
    end
    add_new_report!(analyzer, sv.result, BuiltinErrorReport(sv, f, argtypes, msg))
    return true
end

# TODO use Core.Compiler version when ported
function _mutability_errorcheck(@nospecialize objt0)
    objt = unwrap_unionall(objt0)
    if isa(objt, Union)
        return _mutability_errorcheck(rewrap_unionall(objt.a, objt0)) ||
               _mutability_errorcheck(rewrap_unionall(objt.b, objt0))
    elseif isa(objt, DataType)
        # Can't say anything about abstract types
        isabstracttype(objt) && return true
        return ismutabletype(objt)
    end
    return true
end

function is_division_func(@nospecialize f)
    return (f === Intrinsics.checked_sdiv_int ||
            f === Intrinsics.checked_srem_int ||
            f === Intrinsics.checked_udiv_int ||
            f === Intrinsics.checked_urem_int ||
            f === Intrinsics.sdiv_int ||
            f === Intrinsics.srem_int ||
            f === Intrinsics.udiv_int ||
            f === Intrinsics.urem_int)
end

# TODO this check might be better in its own report pass, say `NumericalPass`
function report_devide_error!(analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(f), argtypes::Argtypes)
    a = argtypes[2]
    t = widenconst(a)
    if isprimitivetype(t) && t <: Number
        if isa(a, Const) && a.val === zero(t)
            report = BuiltinErrorReport(sv, f, argtypes, DEVIDE_ERROR_MSG)
            add_new_report!(analyzer, sv.result, report)
            return true
        end
    end
    return false
end

function handle_invalid_builtins!(analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(f), argtypes::Argtypes, @nospecialize(ret))
    # we don't bail out using `basic_filter` here because the native tfuncs are already very permissive
    if ret === Bottom
        msg = GENERAL_BUILTIN_ERROR_MSG
        report = BuiltinErrorReport(sv, f, argtypes, msg, #=print_signature=#true)
        add_new_report!(analyzer, sv.result, report)
        return true
    end
    return false
end

@jetreport struct UnsoundBuiltinErrorReport <: AbstractBuiltinErrorReport
    @nospecialize(f)
    argtypes::Argtypes
    msg::String = "this builtin function call may throw"
end
print_report_message(io::IO, r::UnsoundBuiltinErrorReport) = print(io, r.msg)
print_signature(::UnsoundBuiltinErrorReport) = true

function (::SoundPass)(::Type{AbstractBuiltinErrorReport}, analyzer::JETAnalyzer, sv::InferenceState, @nospecialize(f), argtypes::Argtypes, @nospecialize(rt))
    # TODO enable this sound pass:
    # - make `stmt_effect_free` work on `InfernceState`
    # - sort out `argextype` interface to make it accept `InfernceState`
    @assert !(f === throw) "`throw` calls shuold be handled either by the report pass of `SeriousExceptionReport` or `UncaughtExceptionReport`"
    if isa(f, IntrinsicFunction)
        if !Core.Compiler.intrinsic_nothrow(f, argtypes)
            add_new_report!(analyzer, sv.result, UnsoundBuiltinErrorReport(sv, f, argtypes))
        end
    else
        nothrow = !(@static isdefined(CC, :typeinf_lattice) ?
            Core.Compiler.builtin_nothrow(CC.typeinf_lattice(analyzer), f, argtypes, rt) :
            Core.Compiler.builtin_nothrow(f, argtypes, rt))
        if nothrow
            add_new_report!(analyzer, sv.result, UnsoundBuiltinErrorReport(sv, f, argtypes))
        end
    end
end
