From ConCert.Extraction Require Import ResultMonad.
From MetaCoq.Template Require Import Ast.
From MetaCoq.Template Require Import LiftSubst.
From MetaCoq.Template Require Import AstUtils.
From MetaCoq.Template Require Import BasicAst.
From MetaCoq.Template Require Import Loader.
From MetaCoq.Template Require Import TemplateMonad.
From MetaCoq.Template Require Import monad_utils.
From MetaCoq.Template Require Import utils.
From MetaCoq.PCUIC Require PCUICAst.
From MetaCoq.Erasure Require EAst.
From MetaCoq.SafeChecker Require Import PCUICSafeChecker.

(** Extracts a constant name, inductive name or returns None *)
Definition to_kername (t : Ast.term) : option kername :=
  match t with
  | Ast.tConst c _ => Some c
  | Ast.tInd c _ => Some c.(inductive_mind)
  | _ => None
  end.

Notation "<%% t %%>" :=
  (ltac:(let p y :=
             let e := eval cbv in (to_kername y) in
             match e with
             | @Some _ ?kn => exact kn
             | _ => fail "not a name"
             end in quote_term t p)).

Definition to_globref (t : Ast.term) : option global_reference :=
  match t with
  | Ast.tConst kn _ => Some (ConstRef kn)
  | Ast.tInd ind _ => Some (IndRef ind)
  | Ast.tConstruct ind c _ => Some (ConstructRef ind c)
  | _ => None
  end.

Notation "<! t !>" :=
  (ltac:(let p y :=
             let e := eval cbv in (to_globref y) in
             match e with
             | @Some _ (ConstRef ?kn) => exact (kn : kername)
             | @Some _ (IndRef ?ind) => exact (ind : inductive)
             | @Some _ (ConstructRef ?ind ?c) => exact ((ind, c) : kername * nat)
             | _ => fail "not a globref"
             end in quote_term t p)).

Import PCUICErrors.

Definition result_of_typing_result
           {A}
           (Σ : PCUICAst.global_env_ext)
           (tr : typing_result A) : result A string :=
  match tr with
  | Checked a => ret a
  | TypeError err => Err (string_of_type_error Σ err)
  end.

Definition string_of_env_error Σ e :=
  match e with
  | IllFormedDecl s e =>
    "IllFormedDecl " ++ s ++ "\nType error: " ++ string_of_type_error Σ e
  | AlreadyDeclared s => "Alreadydeclared " ++ s
  end%string.

Definition result_of_EnvCheck {A} (ec : EnvCheck A) : result A string :=
  match ec with
  | CorrectDecl a => ret a
  | EnvError Σ err => Err (string_of_env_error Σ err)
  end.

Definition result_of_option {A} (o : option A) (err : string) : result A string :=
  match o with
  | Some a => ret a
  | None => Err err
  end.

Definition to_string_name (t : Ast.term) : string :=
  match to_kername t with
  | Some kn => string_of_kername kn
  | None => "Not a constant or inductive"
  end.

Definition extract_def_name {A : Type} (a : A) : TemplateMonad kername :=
  a <- tmEval cbn a;;
  quoted <- tmQuote a;;
  let (head, args) := decompose_app quoted in
  match head with
  | tConst name _ => ret name
  | _ => tmFail ("Expected constant at head, got " ++ string_of_term head)
  end.

Definition extract_def_name_exists {A : Type} (a : A) : TemplateMonad kername :=
  a <- tmEval cbn a;;
  quoted <- tmQuote a;;
  let (head, args) := decompose_app quoted in
  match head with
  | tConstruct ind _ _ =>
    if eq_kername ind.(inductive_mind)
                        <%% sigT %%>
    then match nth_error args 3 with
         | Some (tConst name _) => ret name
         | Some t => tmFail ("Expected constant at second component, got " ++ string_of_term t)
         | None => tmFail ("existT: Expected 4 arguments, found less")
         end
    else tmFail ("Expected constructor existT at head, got " ++ string_of_term head)
  | _ => tmFail ("Expected constructor at head, got " ++ string_of_term head)
  end.

Notation "'unfolded' d" :=
  ltac:(let y := eval unfold d in d in exact y) (at level 100, only parsing).

Definition remap (kn : kername) (new_name : string) : kername * string :=
  (kn, new_name).

Definition EnvCheck_to_template {A } (ec : EnvCheck A) : TemplateMonad A :=
  match ec with
  | CorrectDecl a => ret a
  | EnvError Σ e => tmFail (string_of_env_error Σ e)
  end.

Definition quote_recursively_body {A : Type} (def : A) : TemplateMonad program :=
  p <- tmQuoteRecTransp def false ;;
  kn <- match p.2 with
       | tConst name _ => ret name
       | _ => tmFail ("Expected constant, got "  ++
                       string_of_term p.2)
       end;;
  match lookup_env p.1 kn with
  | Some (ConstantDecl cb) =>
    match cb.(cst_body) with
    | Some b => ret (p.1, b)
    | None => tmFail ("The constant doesn't have a body: " ++ kn.2)
    end
  | _ => tmFail ("Not found: " ++ kn.2)
  end.

Fixpoint update_global_env (Σ : global_env) (Σup : global_env) : global_env :=
  match Σ with
  | (kn, gd) :: Σ' => match lookup_env Σup kn with
                    | Some v => (kn,v) :: update_global_env Σ' Σup
                    | None => (kn, gd) :: update_global_env Σ' Σup
                    end
  | [] => []
  end.

Definition map_subterms (f : term -> term) (t : term) : term :=
  match t with
  | tEvar n ts => tEvar n (map f ts)
  | tCast t kind ty => tCast (f t) kind (f ty)
  | tProd na ty body => tProd na (f ty) (f body)
  | tLambda na ty body => tLambda na (f ty) (f body)
  | tLetIn na val ty body => tLetIn na (f val) (f ty) (f body)
  | tApp hd arg => tApp (f hd) (map f arg)
  | tCase p ty disc brs =>
    tCase p (f ty) (f disc) (map (on_snd f) brs)
  | tProj p t => tProj p (f t)
  | tFix def i => tFix (map (map_def f f) def) i
  | tCoFix def i => tCoFix (map (map_def f f) def) i
  | t => t
  end.

Fixpoint beta_body (body : term) (args : list term) {struct args} : term :=
  match args with
  | [] => body
  | a :: args =>
    match body with
    | tLambda na _ body => beta_body (body{0 := a}) args
    | _ => mkApps body (a :: args)
    end
  end.

Definition iota_body (body : term) : term :=
  match body with
  | tCase (ind, pars, _) _ discr brs =>
    let (hd, args) := decompose_app discr in
    match hd with
    | tConstruct _ c _ =>
      match nth_error brs c with
      | Some (_, br) => beta_body br (skipn pars args)
      | None => body
      end
    | _ => body
    end
  | t => t
  end.

Fixpoint nat_syn_to_nat (t : EAst.term) : option nat :=
  match t with
  | EAst.tApp (EAst.tConstruct ind i) t0 =>
    if eq_kername ind.(inductive_mind) <%% nat %%> then
      match i with
      | 1 => match nat_syn_to_nat t0 with
            | Some v => Some (S v)
            | None => None
            end
      | _ => None
      end
    else None
  | EAst.tConstruct ind 0 =>
    if eq_kername ind.(inductive_mind) <%% nat %%> then
      Some 0
    else None
  | _ => None
  end.

Definition _xI :=
  EAst.tConstruct {| inductive_mind := <%% positive %%>; inductive_ind := 0 |} 0.

Definition _xO :=
  EAst.tConstruct {| inductive_mind := <%% positive %%>; inductive_ind := 0 |} 1.

Definition _xH :=
  EAst.tConstruct {| inductive_mind := <%% positive %%>; inductive_ind := 0 |} 2.

Definition _N0 := EAst.tConstruct {| inductive_mind := <%% N %%>; inductive_ind := 0 |} 0.

Definition _Npos := EAst.tConstruct {| inductive_mind := <%% N %%>; inductive_ind := 0 |} 1.

Definition _Z0 :=  EAst.tConstruct {| inductive_mind := <%% Z %%>; inductive_ind := 0 |} 0.

Definition _Zpos :=  EAst.tConstruct {| inductive_mind := <%% Z %%>; inductive_ind := 0 |} 1.

Definition _Zneg :=  EAst.tConstruct {| inductive_mind := <%% Z %%>; inductive_ind := 0 |} 2.

Print Pos.to_nat.
Fixpoint pos_syn_to_nat_aux (n : nat) (t : EAst.term) : option nat :=
  match t with
  | EAst.tApp (EAst.tConstruct ind i) t0 =>
    if eq_kername ind.(inductive_mind) <%% positive %%> then
      match i with
      | 0 => match pos_syn_to_nat_aux (n + n) t0 with
            | Some v => Some (n + v)
            | None => None
            end
      | 1 => pos_syn_to_nat_aux (n + n) t0
      | _ => None
      end
    else None
  | EAst.tApp _xO t0 => pos_syn_to_nat_aux (n + n) t0
  | EAst.tConstruct ind 2 =>
    if eq_kername ind.(inductive_mind) <%% positive %%> then Some n
    else None
  | _ => None
  end.

Definition pos_syn_to_nat := pos_syn_to_nat_aux 1.

Definition N_syn_to_nat (t : EAst.term) : option nat :=
  match t with
  | EAst.tConstruct ind 0 =>
    if eq_kername ind.(inductive_mind) <%% N %%> then Some 0
    else None
  | EAst.tApp (EAst.tConstruct ind 1) t0 =>
    if eq_kername ind.(inductive_mind) <%% N %%> then
      match pos_syn_to_nat t0 with
      | Some v => Some v
      | None => None
      end
    else None
  | _ => None
  end.

Definition Z_syn_to_Z (t : EAst.term) : option Z :=
  match t with
  | EAst.tConstruct ind 0 =>
    if eq_kername ind.(inductive_mind) <%% Z %%> then Some 0%Z
    else None
  | EAst.tApp (EAst.tConstruct ind i) t0 =>
    if eq_kername ind.(inductive_mind) <%% Z %%> then
      match i with
      | 1 => match pos_syn_to_nat t0 with
            | Some v => Some (Z.of_nat v)
            | None => None
            end
      | 2 => match (pos_syn_to_nat t0) with
            | Some v => Some (-(Z.of_nat v))%Z
            | None => None
            end
      | _ => None
      end
    else None
  | _ => None
  end.
