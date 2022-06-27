From Coq Require Import List.
From Comparse Require Import Monad Combinators.
From MiniHTTPServerFFI Require Import Slice SliceFacts.
From CoqFFI Require Import String.
From ExtLib Require Import Char Monad.

Open Scope string_scope.
Import MonadLetNotation.
Import ApplicativeNotation.
Import ListNotations.

#[local] Existing Instance Monad_stateT.

Inductive directory_id : Type :=
| Dirname (s : Slice.t)
| Current
| Parent.

Inductive uri := make_uri { dirname : list directory_id
                          ; filename : Slice.t
                          }.

#[local]
Fixpoint canonicalize_aux (acc : list directory_id) (dirids : list directory_id)
  : list directory_id :=
  match dirids with
  | Current :: rst => canonicalize_aux acc rst
  | Parent :: rst => canonicalize_aux (tl acc) rst
  | x :: rst => canonicalize_aux (x :: acc) rst
  | [] => rev acc
  end.

Definition canonicalize := canonicalize_aux [].

Definition dirname_eq (d1 d2: list directory_id) : Prop :=
  canonicalize d1 = canonicalize d2.

Inductive canonical : list directory_id -> Prop :=
| canonical_nil : canonical []
| canonical_cons
    (s : Slice.t) (rst : list directory_id) (canonical_rst : canonical rst)
  : canonical (Dirname s :: rst).

Lemma canonical_canonical_tl (d : list directory_id)
  : canonical d -> canonical (tl d).

Proof.
  intros canon.
  destruct d as [ | x rst].
  + auto.
  + now inversion canon.
Qed.

Lemma canonical_canonical_cons (a : directory_id) (d : list directory_id)
  : canonical (a :: d) <-> canonical [a] /\ canonical d.

Proof.
  split.
  + intros canon; inversion canon; subst.
    split; repeat constructor.
    exact canonical_rst.
  + intros [c1 c2].
    inversion c1; subst.
    constructor; auto.
Qed.

Lemma canonical_canonical_app (d1 d2 : list directory_id)
  : canonical d1 /\ canonical d2 <-> canonical (d1 ++ d2).

Proof.
  revert d2.
  induction d1; intros d2.
  + cbn.
    split.
    ++ now intros [_ exact].
    ++ intros exact; split; [ constructor | auto ].
  + cbn.
    rewrite (canonical_canonical_cons a d1).
    rewrite (canonical_canonical_cons a (d1 ++ d2)).
    rewrite <- IHd1.
    now rewrite and_assoc.
Qed.

Lemma canonical_canonical_rev (d : list directory_id)
  : canonical d <-> canonical (rev d).

Proof.
  induction d.
  + reflexivity.
  + cbn.
    rewrite canonical_canonical_cons.
    rewrite <- (canonical_canonical_app (rev d) [a]).
    now rewrite IHd.
Qed.

#[local]
Lemma canonicalize_aux_canonical (d acc : list directory_id)
    (acc_canon : canonical acc)
  : canonical (canonicalize_aux acc d).

Proof.
  revert acc acc_canon.
  induction d; intros acc acc_canon.
  + cbn.
    now rewrite <- canonical_canonical_rev.
  + destruct a.
    ++ cbn.
       apply IHd.
       constructor; auto.
    ++ cbn.
       now apply IHd.
    ++ cbn.
       apply IHd.
       now apply canonical_canonical_tl.
Qed.

Lemma canonicalize_canonical (d : list directory_id)
  : canonical (canonicalize d).

Proof.
  apply canonicalize_aux_canonical.
  constructor.
Qed.

#[local]
Remark canonical_canonicalize_aux_cons_equ
    (d : list directory_id) (canon : canonical d) (acc : list directory_id)
  : canonicalize_aux acc d = List.app (rev acc) (canonicalize_aux nil d).

Proof.
  revert acc.
  induction d.
  + intros acc.
    now rewrite <- app_nil_end.
  + intros acc.
    cbn.
    inversion canon; subst.
    rewrite IHd; auto.
    cbn.
    rewrite <- app_assoc.
    now erewrite (IHd canonical_rst [Dirname s]).
Qed.

Remark canonical_canonicalize_cons_equ (s : Slice.t)
    (d : list directory_id) (canon : canonical d)
  : canonicalize (Dirname s :: d) = Dirname s :: canonicalize d.

Proof.
  unfold canonicalize.
  cbn.
  now rewrite canonical_canonicalize_aux_cons_equ.
Qed.

Lemma canonicalize_canonical_equ (d : list directory_id) (canon : canonical d)
  : canonicalize d = d.

Proof.
  induction d.
  + auto.
  + inversion canon; subst.
    rewrite canonical_canonicalize_cons_equ; auto.
    rewrite IHd; auto.
Qed.

Lemma canonicalize_idempontent (d : list directory_id)
  : canonicalize (canonicalize d) = canonicalize d.

Proof.
  rewrite canonicalize_canonical_equ; [ reflexivity | ].
  apply canonicalize_canonical.
Qed.

#[program, local]
Fixpoint uri_to_path_aux (d : list directory_id) (canon : canonical d) : string :=
  match d with
  | [] => ""
  | Dirname x :: rst => (Slice.to_string x) ++ "/" ++ uri_to_path_aux rst _
  | Parent :: _ => _
  | Current :: _ => _
  end.

Next Obligation.
  inversion canon; auto.
Defined.

Next Obligation.
  exfalso; inversion canon.
Defined.

Next Obligation.
  exfalso; inversion canon.
Defined.

#[program]
Definition uri_to_path (u : uri) : string :=
  "/" ++ uri_to_path_aux (canonicalize (dirname u)) _ ++ Slice.to_string (filename u).

Next Obligation.
  apply canonicalize_canonical.
Qed.

Definition sandbox (base : list directory_id) (req : uri) : uri :=
  make_uri (List.app base (canonicalize (dirname req))) (filename req).

(** * Parsing URI *)

Definition char (c : ascii) : parser Slice.t ascii := token c.
Definition str (t : string) : parser Slice.t unit := tag (t := ascii) (Slice.of_string t).

#[global] Axiom str_Parser : forall x rst, Parser slice_length (str (String x rst)).
#[global] Axiom str_StrictParser : forall x rst, StrictParser slice_length (str (String x rst)).

Existing Instance str_Parser.
Existing Instance str_StrictParser.

Definition dir_id_sep : parser Slice.t unit :=
  eoi <|> skip (char "/") <|> skip (char " ").

Definition uri_char : parser Slice.t ascii :=
  ensure read_token (fun x => negb ((eqb x " ") || (eqb x "/"))).

Definition dirid : parser Slice.t directory_id :=
  many (char "/");;
  (let* name := some_until uri_char (peek dir_id_sep) in
   peek (char "/");;
   pure (Dirname (Slice.pack name)))
  <|> (str "..";;
       peek dir_id_sep;;
       pure Parent)
  <|> (char ".";;
       peek dir_id_sep;;
       pure Current).

Definition path_dirname : parser Slice.t (list directory_id) := many dirid.

Definition path_filename : parser Slice.t Slice.t :=
  let* candidat := many uri_char in
  match candidat with
  | [] => pure (Slice.of_string "index.html")
  | x => pure (Slice.pack x)
  end.

Definition read_uri : parser Slice.t uri :=
  let* dir := path_dirname in
  many (char "/");;
  let* file := path_filename in
  pure (make_uri dir file).
