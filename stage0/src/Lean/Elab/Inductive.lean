/-
Copyright (c) 2020 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
import Lean.Util.ReplaceLevel
import Lean.Util.ReplaceExpr
import Lean.Util.CollectLevelParams
import Lean.Util.Constructions
import Lean.Elab.Command
import Lean.Elab.CollectFVars
import Lean.Elab.Definition

namespace Lean
namespace Elab
namespace Command

def checkValidInductiveModifier (ref : Syntax) (modifiers : Modifiers) : CommandElabM Unit := do
when modifiers.isNoncomputable $
  throwError ref "invalid use of 'noncomputable' in inductive declaration";
when modifiers.isPartial $
  throwError ref "invalid use of 'partial' in inductive declaration";
unless (modifiers.attrs.size == 0 || (modifiers.attrs.size == 1 && (modifiers.attrs.get! 0).name == `class)) $
  throwError ref "invalid use of attributes in inductive declaration";
pure ()

def checkValidCtorModifier (ref : Syntax) (modifiers : Modifiers) : CommandElabM Unit := do
when modifiers.isNoncomputable $
  throwError ref "invalid use of 'noncomputable' in constructor declaration";
when modifiers.isPartial $
  throwError ref "invalid use of 'partial' in constructor declaration";
when modifiers.isUnsafe $
  throwError ref "invalid use of 'unsafe' in constructor declaration";
when (modifiers.attrs.size != 0) $
  throwError ref "invalid use of attributes in constructor declaration";
pure ()


structure CtorView :=
(ref       : Syntax)
(modifiers : Modifiers)
(inferMod  : Bool)  -- true if `{}` is used in the constructor declaration
(declName  : Name)
(binders   : Syntax)
(type?     : Option Syntax)

instance CtorView.inhabited : Inhabited CtorView :=
⟨{ ref := arbitrary _, modifiers := {}, inferMod := false, declName := arbitrary _, binders := arbitrary _, type? := none }⟩

structure InductiveView :=
(ref           : Syntax)
(modifiers     : Modifiers)
(shortDeclName : Name)
(declName      : Name)
(levelNames    : List Name)
(binders       : Syntax)
(type?         : Option Syntax)
(ctors         : Array CtorView)

instance InductiveView.inhabited : Inhabited InductiveView :=
⟨{ ref := arbitrary _, modifiers := {}, shortDeclName := arbitrary _, declName := arbitrary _,
   levelNames := [], binders := arbitrary _, type? := none, ctors := #[] }⟩

structure ElabHeaderResult :=
(view       : InductiveView)
(lctx       : LocalContext)
(localInsts : LocalInstances)
(params     : Array Expr)
(type       : Expr)

instance ElabHeaderResult.inhabited : Inhabited ElabHeaderResult :=
⟨{ view := arbitrary _, lctx := arbitrary _, localInsts := arbitrary _, params := #[], type := arbitrary _ }⟩

private partial def elabHeaderAux (views : Array InductiveView)
    : Nat → Array ElabHeaderResult → TermElabM (Array ElabHeaderResult)
| i, acc =>
  if h : i < views.size then
    let view := views.get ⟨i, h⟩;
    Term.elabBinders view.binders.getArgs fun params => do
      lctx ← Term.getLCtx;
      localInsts ← Term.getLocalInsts;
      match view.type? with
      | none         => do
        u ← Term.mkFreshLevelMVar view.ref;
        let type := mkSort (mkLevelSucc u);
        elabHeaderAux (i+1) (acc.push { lctx := lctx, localInsts := localInsts, params := params, type := type, view := view })
      | some typeStx => do
        type ← Term.elabTerm typeStx none;
        unlessM (Term.isTypeFormerType view.ref type) $
          Term.throwError typeStx "invalid inductive type, resultant type is not a sort";
        elabHeaderAux (i+1) (acc.push { lctx := lctx, localInsts := localInsts, params := params, type := type, view := view })
  else
    pure acc

private def checkNumParams (rs : Array ElabHeaderResult) : TermElabM Nat := do
let numParams := (rs.get! 0).params.size;
rs.forM fun r => unless (r.params.size == numParams) $
  Term.throwError r.view.ref "invalid inductive type, number of parameters mismatch in mutually inductive datatypes";
pure numParams

private def checkUnsafe (rs : Array ElabHeaderResult) : TermElabM Unit :=
let isUnsafe := (rs.get! 0).view.modifiers.isUnsafe;
rs.forM fun r => unless (r.view.modifiers.isUnsafe == isUnsafe) $
  Term.throwError r.view.ref "invalid inductive type, cannot mix unsafe and safe declarations in a mutually inductive datatypes"

private def checkLevelNames (views : Array InductiveView) : TermElabM Unit :=
when (views.size > 1) do
  let levelNames := (views.get! 0).levelNames;
  views.forM fun view => unless (view.levelNames == levelNames) $
    Term.throwError view.ref "invalid inductive type, universe parameters mismatch in mutually inductive datatypes"

private def mkTypeFor (r : ElabHeaderResult) : TermElabM Expr := do
Term.withLocalContext r.lctx r.localInsts do
  Term.mkForall r.view.ref r.params r.type

private def throwUnexpectedInductiveType {α} (ref : Syntax) : TermElabM α :=
Term.throwError ref "unexpected inductive resulting type"

-- Given `e` of the form `forall As, B`, return `B`.
private def getResultingType (ref : Syntax) (e : Expr) : TermElabM Expr :=
Term.liftMetaM ref $ Meta.forallTelescopeReducing e fun _ r => pure r

private def eqvFirstTypeResult (firstType type : Expr) : MetaM Bool :=
Meta.forallTelescopeReducing firstType fun _ firstTypeResult => Meta.isDefEq firstTypeResult type

-- Auxiliary function for checking whether the types in mutually inductive declaration are compatible.
private partial def checkParamsAndResultType (ref : Syntax) (numParams : Nat) : Nat → Expr → Expr → TermElabM Unit
| i, type, firstType => do
  type ← Term.whnf ref type;
  if i < numParams then do
    firstType ← Term.whnf ref firstType;
    match type, firstType with
    | Expr.forallE n₁ d₁ b₁ c₁, Expr.forallE n₂ d₂ b₂ c₂ => do
      unless (n₁ == n₂) $
        let msg : MessageData :=
          "invalid mutually inductive types, parameter name mismatch '" ++ n₁ ++ "', expected '" ++ n₂ ++ "'";
        Term.throwError ref msg;
      unlessM (Term.isDefEq ref d₁ d₂) $
        let msg : MessageData :=
          "invalid mutually inductive types, type mismatch at parameter '" ++ n₁ ++ "'" ++ indentExpr d₁
          ++ Format.line ++ "expected type" ++ indentExpr d₂;
        Term.throwError ref msg;
      unless (c₁.binderInfo == c₂.binderInfo) $
        -- TODO: improve this error message?
        Term.throwError ref ("invalid mutually inductive types, binder annotation mismatch at parameter '" ++ n₁ ++ "'");
      Term.withLocalDecl ref n₁ c₁.binderInfo d₁ fun x =>
        let type      := b₁.instantiate1 x;
        let firstType := b₂.instantiate1 x;
        checkParamsAndResultType (i+1) type firstType
    | _, _ => throwUnexpectedInductiveType ref
  else
    match type with
    | Expr.forallE n d b c =>
      Term.withLocalDecl ref n c.binderInfo d fun x =>
        let type      := b.instantiate1 x;
        checkParamsAndResultType (i+1) type firstType
    | Expr.sort _ _        =>
      unlessM (Term.liftMetaM ref $ eqvFirstTypeResult firstType type) $
        let msg : MessageData :=
          "invalid mutually inductive types, resulting universe mismatch, given " ++ indentExpr type ++ Format.line ++ "expected type" ++ indentExpr firstType;
        Term.throwError ref msg
    | _ => throwUnexpectedInductiveType ref

-- Auxiliary function for checking whether the types in mutually inductive declaration are compatible.
private def checkHeader (r : ElabHeaderResult) (numParams : Nat) (firstType? : Option Expr) : TermElabM Expr := do
type ← mkTypeFor r;
match firstType? with
| none           => pure type
| some firstType => do
  checkParamsAndResultType r.view.ref numParams 0 type firstType;
  pure firstType

-- Auxiliary function for checking whether the types in mutually inductive declaration are compatible.
private partial def checkHeaders (rs : Array ElabHeaderResult) (numParams : Nat) : Nat → Option Expr → TermElabM Unit
| i, firstType? => when (i < rs.size) do
  type ← checkHeader (rs.get! i) numParams firstType?;
  checkHeaders (i+1) type

private def elabHeader (views : Array InductiveView) : TermElabM (Array ElabHeaderResult) := do
rs ← elabHeaderAux views 0 #[];
when (rs.size > 1) do {
  checkUnsafe rs;
  numParams ← checkNumParams rs;
  checkHeaders rs numParams 0 none
};
pure rs

private partial def withInductiveLocalDeclsAux {α} (ref : Syntax) (namesAndTypes : Array (Name × Expr)) (params : Array Expr)
    (x : Array Expr → Array Expr → TermElabM α) : Nat → Array Expr → TermElabM α
| i, indFVars =>
  if h : i < namesAndTypes.size then do
    let (id, type) := namesAndTypes.get ⟨i, h⟩;
    type ← Term.liftMetaM ref (Meta.instantiateForall type params);
    Term.withLocalDecl ref id BinderInfo.default type fun indFVar => withInductiveLocalDeclsAux (i+1) (indFVars.push indFVar)
  else
    x params indFVars

/- Create a local declaration for each inductive type in `rs`, and execute `x params indFVars`, where `params` are the inductive type parameters and
   `indFVars` are the new local declarations.
   We use the the local context/instances and parameters of rs[0].
   Note that this method is executed after we executed `checkHeaders` and established all
   parameters are compatible. -/
private def withInductiveLocalDecls {α} (rs : Array ElabHeaderResult) (x : Array Expr → Array Expr → TermElabM α) : TermElabM α := do
namesAndTypes ← rs.mapM fun r => do {
  type ← mkTypeFor r;
  pure (r.view.shortDeclName, type)
};
let r0     := rs.get! 0;
let params := r0.params;
Term.withLocalContext r0.lctx r0.localInsts $
  withInductiveLocalDeclsAux r0.view.ref namesAndTypes params x 0 #[]

private def isInductiveFamily (ref : Syntax) (indFVar : Expr) : TermElabM Bool := do
indFVarType ← Term.inferType ref indFVar;
indFVarType ← Term.whnf ref indFVarType;
pure !indFVarType.isSort

/-
  Elaborate constructor types.

  Remark: we check whether the resulting type is correct, but
  we do not check for:
  - Positivity (it is a rare failure, and the kernel already checks for it).
  - Universe constraints (the kernel checks for it). -/
private def elabCtors (indFVar : Expr) (params : Array Expr) (r : ElabHeaderResult) : TermElabM (List Constructor) := do
let ref := r.view.ref;
indFamily ← isInductiveFamily ref indFVar;
r.view.ctors.toList.mapM fun ctorView => Term.elabBinders ctorView.binders.getArgs fun ctorParams => do
  let ref := ctorView.ref;
  type ← match ctorView.type? with
    | none          => do
      when indFamily $
        Term.throwError ref "constructor resulting type must be specified in inductive family declaration";
      pure indFVar
    | some ctorType => do {
      type ← Term.elabTerm ctorType none;
      resultingType ← getResultingType ref type;
      unless (resultingType.getAppFn == indFVar) $
        Term.throwError ref ("unexpected constructor resulting type" ++ indentExpr resultingType);
      unlessM (Term.isType ref resultingType) $
        Term.throwError ref ("unexpected constructor resulting type, type expected" ++ indentExpr resultingType);
      pure type
    };
  type ← Term.mkForall ref ctorParams type;
  type ← Term.mkForall ref params type;
  pure { name := ctorView.declName, type := type }

/- Convert universe metavariables occurring in the `indTypes` into new parameters.
   Remark: if the resulting inductive datatype has universe metavariables, we will fix it later using
   `inferResultingUniverse`. -/
private def levelMVarToParamAux (ref : Syntax) (indTypes : List InductiveType) : StateT Nat TermElabM (List InductiveType) :=
indTypes.mapM fun indType => do
  type  ← liftM $ Term.instantiateMVars ref indType.type;
  type  ← Term.levelMVarToParam' type;
  ctors ← indType.ctors.mapM fun ctor => do {
    ctorType ← liftM $ Term.instantiateMVars ref ctor.type;
    ctorType ← Term.levelMVarToParam' ctorType;
    pure { ctor with type := ctorType }
  };
  pure { indType with ctors := ctors, type := type }

private def levelMVarToParam (ref : Syntax) (indTypes : List InductiveType) : TermElabM (List InductiveType) :=
(levelMVarToParamAux ref indTypes).run' 1

private def getResultingUniverse (ref : Syntax) : List InductiveType → TermElabM Level
| []           => Term.throwError ref "unexpected empty inductive declaration"
| indType :: _ => do
  r ← getResultingType ref indType.type;
  match r with
  | Expr.sort u _ => pure u
  | _             => Term.throwError ref "unexpected inductive type resulting type"

private def tmpIndParam := mkLevelParam `_tmp_ind_univ_param

/--
  Return true if the resulting universe level is of the form `?m + k`.
  Return false if the resulting universe level does not contain universe metavariables.
  Throw exeception otherwise. -/
private def shouldInferResultUniverse (ref : Syntax) (indTypes : List InductiveType) : TermElabM Bool := do
u ← getResultingUniverse ref indTypes;
u ← Term.instantiateLevelMVars ref u;
if u.hasMVar then
  match u.getLevelOffset with
  | Level.mvar mvarId _ => do
    Term.assignLevelMVar mvarId tmpIndParam;
    pure true
  | _ =>
    Term.throwError ref $
      "cannot infer resulting universe level of inductive datatype, given level contains metavariables " ++ mkSort u ++ ", provide universe explicitly"
else
  pure false

/-
  Auxiliary function for `updateResultingUniverse`
  `addLevel u r rOffset us` add `u` components to `us` if they are not already there and it is different from the resulting universe level `r+rOffset`.
  If `u` is a `max`, then its components are recursively processed.
  If `u` is a `succ` and `rOffset > 0`, we process the `u`s child using `rOffset-1`.

  This method is used to infer the resulting universe level of an inductive datatype. -/
private def addLevel : Level → Level → Nat → Array Level → Except String (Array Level)
| Level.max u v _, r, rOffset,   us => do us ← addLevel u r rOffset us; addLevel v r rOffset us
| Level.zero _,    _, _,         us => pure us
| Level.succ u _,  r, rOffset+1, us => addLevel u r rOffset us
| u,               r, rOffset,   us =>
  if rOffset == 0 && u == r then pure us
  else if r.occurs u then throw "failed to compute resulting universe level of inductive datatype, provide universe explicitly"
  else if us.contains u then pure us
  else pure (us.push u)

/- Auxiliary function for `updateResultingUniverse` -/
private partial def collectUniversesFromCtorTypeAux (ref : Syntax) (r : Level) (rOffset : Nat) : Nat → Expr → Array Level → TermElabM (Array Level)
| 0,   Expr.forallE n d b c, us => do
  u ← Term.getLevel ref d;
  u ← Term.instantiateLevelMVars ref u;
  match addLevel u r rOffset us with
  | Except.error msg => Term.throwError ref msg
  | Except.ok us     => Term.withLocalDecl ref n c.binderInfo d $ fun x =>
    let e := b.instantiate1 x;
    collectUniversesFromCtorTypeAux 0 e us
| i+1, Expr.forallE n d b c, us => do
  Term.withLocalDecl ref n c.binderInfo d $ fun x =>
    let e := b.instantiate1 x;
    collectUniversesFromCtorTypeAux i e us
| _, _, us => pure us

/- Auxiliary function for `updateResultingUniverse` -/
private partial def collectUniversesFromCtorType
    (ref : Syntax) (r : Level) (rOffset : Nat) (ctorType : Expr) (numParams : Nat) (us : Array Level) : TermElabM (Array Level) :=
collectUniversesFromCtorTypeAux ref r rOffset numParams ctorType us

/- Auxiliary function for `updateResultingUniverse` -/
private partial def collectUniverses (ref : Syntax) (r : Level) (rOffset : Nat) (numParams : Nat) (indTypes : List InductiveType) : TermElabM (Array Level) :=
indTypes.foldlM
  (fun us indType => indType.ctors.foldlM
    (fun us ctor => collectUniversesFromCtorType ref r rOffset ctor.type numParams us)
    us)
  #[]

private def updateResultingUniverse (ref : Syntax) (numParams : Nat) (indTypes : List InductiveType) : TermElabM (List InductiveType) := do
r ← getResultingUniverse ref indTypes;
let rOffset : Nat   := r.getOffset;
let r       : Level := r.getLevelOffset;
unless (r.isParam) $
  Term.throwError ref "failed to compute resulting universe level of inductive datatype, provide universe explicitly";
us ← collectUniverses ref r rOffset numParams indTypes;
let rNew := Level.mkNaryMax us.toList;
pure $ indTypes.map fun indType =>
  let type := indType.type.replaceLevel fun u => if u == tmpIndParam then some rNew else none;
  { indType with type := type }

private def traceIndTypes (indTypes : List InductiveType) : TermElabM Unit :=
indTypes.forM fun indType =>
  indType.ctors.forM fun ctor => _root_.dbgTrace ("  >> " ++ toString ctor.name ++ " : " ++ toString ctor.type) fun _ => pure ()

private def removeUnused (ref : Syntax) (vars : Array Expr) (indTypes : List InductiveType) : TermElabM (LocalContext × LocalInstances × Array Expr) := do
used ← indTypes.foldlM
  (fun (used : CollectFVars.State) indType => do
    used ← Term.collectUsedFVars ref used indType.type;
    indType.ctors.foldlM (fun (used : CollectFVars.State) ctor => Term.collectUsedFVars ref used ctor.type) used)
  {};
Term.removeUnused ref vars used

private def withUsed {α} (ref : Syntax) (vars : Array Expr) (indTypes : List InductiveType) (k : Array Expr → TermElabM α) : TermElabM α := do
(lctx, localInsts, vars) ← removeUnused ref vars indTypes;
Term.withLCtx lctx localInsts $ k vars

private def updateParams (ref : Syntax) (vars : Array Expr) (indTypes : List InductiveType) : TermElabM (List InductiveType) :=
indTypes.mapM fun indType => do
  type ← Term.mkForall ref vars indType.type;
  ctors ← indType.ctors.mapM fun ctor => do {
    ctorType ← Term.mkForall ref vars ctor.type;
    pure { ctor with type := ctorType }
  };
  pure { indType with type := type, ctors := ctors }

private def collectLevelParamsInInductive (indTypes : List InductiveType) : Array Name :=
let usedParams := indTypes.foldl
  (fun (usedParams : CollectLevelParams.State) indType =>
    let usedParams := collectLevelParams usedParams indType.type;
    indType.ctors.foldl
      (fun (usedParams : CollectLevelParams.State) ctor => collectLevelParams usedParams ctor.type)
      usedParams)
  {};
usedParams.params

private def mkIndFVar2Const (views : Array InductiveView) (indFVars : Array Expr) (levelNames : List Name) : ExprMap Expr :=
let levelParams := levelNames.map mkLevelParam;
views.size.fold
  (fun i (m : ExprMap Expr) =>
    let view    := views.get! i;
    let indFVar := indFVars.get! i;
    m.insert indFVar (mkConst view.declName levelParams))
  {}

private def replaceIndFVarsWithConsts (views : Array InductiveView) (indFVars : Array Expr) (levelNames : List Name) (numParams : Nat) (indTypes : List InductiveType)
    : TermElabM (List InductiveType) :=
let ref           := (views.get! 0).ref;
let indFVar2Const := mkIndFVar2Const views indFVars levelNames;
indTypes.mapM fun indType => do
  ctors ← indType.ctors.mapM fun ctor => do {
    type ← Term.liftMetaM ref $ Meta.forallBoundedTelescope ctor.type numParams fun params type => do {
      let type := type.replace fun e => if !e.isFVar then none else
        match indFVar2Const.find? e with
        | some c => some $ mkAppN c params
        | none   => none;
      Meta.mkForall params type
    };
    pure { ctor with type := type }
  };
  pure { indType with ctors := ctors }

abbrev Ctor2InferMod := Std.HashMap Name Bool

private def mkCtor2InferMod (views : Array InductiveView) : Ctor2InferMod :=
views.foldl
  (fun (m : Ctor2InferMod) view => view.ctors.foldl
    (fun (m : Ctor2InferMod) ctorView => m.insert ctorView.declName ctorView.inferMod)
    m)
  {}

private def applyInferMod (views : Array InductiveView) (numParams : Nat) (indTypes : List InductiveType) : List InductiveType :=
let ctor2InferMod := mkCtor2InferMod views;
indTypes.map fun indType =>
  let ctors := indType.ctors.map fun ctor =>
    let inferMod := ctor2InferMod.find! ctor.name; -- true if `{}` was used
    let ctorType := ctor.type.inferImplicit numParams !inferMod;
    { ctor with type := ctorType };
  { indType with ctors := ctors }

private def mkInductiveDecl (vars : Array Expr) (views : Array InductiveView) : TermElabM Declaration := do
let view0             := views.get! 0;
scopeLevelNames ← Term.getLevelNames;
checkLevelNames views;
let allUserLevelNames := view0.levelNames;
let isUnsafe          := view0.modifiers.isUnsafe;
let ref               := view0.ref;
adaptReader (fun (ctx : Term.Context) => { ctx with levelNames := allUserLevelNames }) do
  rs ← elabHeader views;
  withInductiveLocalDecls rs fun params indFVars => do
    let numExplicitParams := params.size;
    indTypes ← views.size.foldM
      (fun i (indTypes : List InductiveType) => do
        let indFVar := indFVars.get! i;
        let r       := rs.get! i;
        type  ← Term.mkForall ref params r.type;
        ctors ← elabCtors indFVar params r;
        let indType := { name := r.view.declName, type := type, ctors := ctors : InductiveType };
        pure (indType :: indTypes))
      [];
    let indTypes := indTypes.reverse;
    Term.synthesizeSyntheticMVars false;  -- resolve pending
    inferLevel ← shouldInferResultUniverse ref indTypes;
    withUsed ref vars indTypes $ fun vars => do
      let numParams := vars.size + numExplicitParams;
      indTypes ← updateParams ref vars indTypes;
      indTypes ← levelMVarToParam ref indTypes;
      indTypes ← if inferLevel then updateResultingUniverse ref numParams indTypes else pure indTypes;
      let usedLevelNames := collectLevelParamsInInductive indTypes;
      match sortDeclLevelParams scopeLevelNames allUserLevelNames usedLevelNames with
      | Except.error msg      => Term.throwError ref msg
      | Except.ok levelParams => do
        indTypes ← replaceIndFVarsWithConsts views indFVars levelParams numParams indTypes;
        let indTypes := applyInferMod views numParams indTypes;
        pure $ Declaration.inductDecl levelParams numParams indTypes isUnsafe

private def mkAuxConstructions (views : Array InductiveView) : CommandElabM Unit := do
env ← getEnv;
let hasEq   := env.contains `Eq;
let hasHEq  := env.contains `HEq;
let hasUnit := env.contains `PUnit;
let hasProd := env.contains `Prod;
views.forM fun view => do {
  let n := view.declName;
  modifyEnv fun env => mkRecOn env n;
  when hasUnit $ modifyEnv fun env => mkCasesOn env n;
  when (hasUnit && hasEq && hasHEq) $ modifyEnv fun env => mkNoConfusion env n;
  when (hasUnit && hasProd) $ modifyEnv fun env => mkBelow env n;
  when (hasUnit && hasProd) $ modifyEnv fun env => mkIBelow env n;
  pure ()
};
views.forM fun view => do {
  let n := view.declName;
  when (hasUnit && hasProd) $ modifyEnv fun env => mkBRecOn env n;
  when (hasUnit && hasProd) $ modifyEnv fun env => mkBInductionOn env n;
  pure ()
}

def elabInductiveViews (views : Array InductiveView) : CommandElabM Unit := do
let view0 := views.get! 0;
let ref   := view0.ref;
decl ← runTermElabM view0.declName $ fun vars => mkInductiveDecl vars views;
addDecl ref decl;
mkAuxConstructions views;
-- We need to invoke `applyAttributes` because `class` is implemented as an attribute.
views.forM fun view => applyAttributes ref view.declName view.modifiers.attrs AttributeApplicationTime.afterTypeChecking;
pure ()

end Command
end Elab
end Lean
