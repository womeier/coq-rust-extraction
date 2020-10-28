(* This implements an optimization that changes top level fixpoints to use
   tConst instead. For example, the environment [("Foo", tFix [{| dbody := tRel 0 |}] 0)]
   is instead changed into something like [("Foo", tConst "Foo")]. *)

From Coq Require Import Arith.
From ConCert.Extraction Require Import ExAst.
From MetaCoq.Erasure Require Import ELiftSubst.

Fixpoint opt_term_aux (t : term) (kn : kername) (lams : nat) :=
  match t with
  | tLambda na body => tLambda na (opt_term_aux body kn (S lams))
  | tFix [def] 0 => (dbody def){0 := mkApps (tConst kn) (rev_map tRel (seq 0 lams))}
  | _ => t
  end.

Definition opt_term (t : term) (kn : kername) : term :=
    opt_term_aux t kn 0.

Definition opt_decl (p : kername * bool * global_decl) :=
  let '(kn, includes_deps, decl) := p in
  let new_decl :=
      match decl with
      | ConstantDecl cst =>
        ConstantDecl {| cst_type := cst_type cst;
                        cst_body := option_map (fun t => opt_term t kn) (cst_body cst); |}
      | _ => decl
      end in
  (kn, includes_deps, new_decl).

Definition opt_top_level_fixes (Σ : global_env) : global_env :=
  map opt_decl Σ.
