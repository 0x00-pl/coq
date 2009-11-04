(* -*- compile-command: "make -C .. bin/coqtop.byte" -*- *)
(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id$ i*)

(*i*)
open Names
open Decl_kinds
open Term
open Termops
open Sign
open Entries
open Evd
open Environ
open Nametab
open Mod_subst
open Util
open Typeclasses_errors
open Typeclasses
open Libnames
open Constrintern
open Rawterm
open Topconstr
(*i*)

open Decl_kinds
open Entries

let typeclasses_db = "typeclass_instances"

let set_typeclass_transparency c b = 
  Auto.add_hints false [typeclasses_db] 
    (Auto.HintsTransparencyEntry ([c], b))
    
let _ =
  Typeclasses.register_add_instance_hint
    (fun inst pri ->
      Flags.silently (fun () ->
	Auto.add_hints false [typeclasses_db]
	  (Auto.HintsResolveEntry
	      [pri, false, constr_of_global inst])) ());
  Typeclasses.register_set_typeclass_transparency set_typeclass_transparency
    
let declare_class glob idl =
  match global (Ident idl) with
  | ConstRef x -> Typeclasses.add_constant_class x
  | IndRef x -> Typeclasses.add_inductive_class x
  | _ -> user_err_loc (fst idl, "declare_class", 
		      Pp.str"Unsupported class type, only constants and inductives are allowed")
    
let declare_instance_cst glob c =
  let instance = Typing.type_of (Global.env ()) Evd.empty (constr_of_global c) in
  let _, r = decompose_prod_assum instance in
    match class_of_constr r with
      | Some tc -> add_instance (new_instance tc None glob c)
      | None -> errorlabstrm "" (Pp.strbrk "Constant does not build instances of a declared type class.")

let declare_instance glob idl =
  let con = 
    try global (Ident idl)
    with _ -> error "Instance definition not found."
  in declare_instance_cst glob con

let mismatched_params env n m = mismatched_ctx_inst env Parameters n m
let mismatched_props env n m = mismatched_ctx_inst env Properties n m

type binder_list = (identifier located * bool * constr_expr) list

(* Calls to interpretation functions. *)

let interp_type_evars evdref env ?(impls=([],[])) typ =
  let typ' = intern_gen true ~impls !evdref env typ in
  let imps = Implicit_quantifiers.implicits_of_rawterm typ' in
    imps, Pretyping.Default.understand_tcc_evars evdref env Pretyping.IsType typ'

(* Declare everything in the parameters as implicit, and the class instance as well *)

open Topconstr

let type_ctx_instance evars env ctx inst subst =
  let (s, _) =
    List.fold_left2
      (fun (subst, instctx) (na, b, t) ce ->
	let t' = substl subst t in
	let c' =
	  match b with
	  | None -> interp_casted_constr_evars evars env ce t'
	  | Some b -> substl subst b
	in
	let d = na, Some c', t' in
	  c' :: subst, d :: instctx)
      (subst, []) (List.rev ctx) inst
  in s

let refine_ref = ref (fun _ -> assert(false))

let id_of_class cl =
  match cl.cl_impl with
    | ConstRef kn -> let _,_,l = repr_con kn in id_of_label l
    | IndRef (kn,i) ->
	let mip = (Environ.lookup_mind kn (Global.env ())).Declarations.mind_packets in
	  mip.(0).Declarations.mind_typename
    | _ -> assert false

open Pp

let ($$) g f = fun x -> g (f x)

let instance_hook k pri global imps ?hook cst =
  let inst = Typeclasses.new_instance k pri global cst in
    Impargs.maybe_declare_manual_implicits false cst ~enriching:false imps;
    Typeclasses.add_instance inst;
    (match hook with Some h -> h cst | None -> ())

let declare_instance_constant k pri global imps ?hook id term termtype =
  let cdecl =
    let kind = IsDefinition Instance in
    let entry =
      { const_entry_body   = term;
	const_entry_type   = Some termtype;
	const_entry_opaque = false;
	const_entry_boxed  = false }
    in DefinitionEntry entry, kind
  in
  let kn = Declare.declare_constant id cdecl in
    Flags.if_verbose Command.definition_message id;
    instance_hook k pri global imps ?hook (ConstRef kn);
    id

let new_instance ?(global=false) ctx (instid, bk, cl) props ?(generalize=true)
    ?(tac:Proof_type.tactic option) ?(hook:(global_reference -> unit) option) pri =
  let env = Global.env() in
  let evars = ref Evd.empty in
  let tclass, ids =
    match bk with
    | Implicit ->
	Implicit_quantifiers.implicit_application Idset.empty ~allow_partial:false
	  (fun avoid (clname, (id, _, t)) ->
	    match clname with
	    | Some (cl, b) ->
		let t = CHole (Util.dummy_loc, None) in
		  t, avoid
	    | None -> failwith ("new instance: under-applied typeclass"))
	  cl
    | Explicit -> cl, Idset.empty
  in
  let tclass = if generalize then CGeneralization (dummy_loc, Implicit, Some AbsPi, tclass) else tclass in
  let k, ctx', len, imps, subst =
    let (env', ctx), imps = interp_context_evars evars env ctx in
    let c', imps' = interp_type_evars_impls ~evdref:evars env' tclass in
    let len = List.length ctx in
    let imps = imps @ Impargs.lift_implicits len imps' in
    let ctx', c = decompose_prod_assum c' in
    let ctx' = ctx' @ ctx in
    let cl, args = Typeclasses.dest_class_app (push_rel_context ctx' env) c in
      cl, ctx', len, imps, List.rev args
  in
  let id =
    match snd instid with
	Name id ->
	  let sp = Lib.make_path id in
	    if Nametab.exists_cci sp then
	      errorlabstrm "new_instance" (Nameops.pr_id id ++ Pp.str " already exists.");
	    id
      | Anonymous ->
	  let i = Nameops.add_suffix (id_of_class k) "_instance_0" in
	    Termops.next_global_ident_away false i (Termops.ids_of_context env)
  in
  let env' = push_rel_context ctx' env in
  evars := Evarutil.nf_evar_defs !evars;
  evars := resolve_typeclasses env !evars;
  let sigma =  !evars in
  let subst = List.map (Evarutil.nf_evar sigma) subst in
    if Lib.is_modtype () then
      begin
	let _, ty_constr = instance_constructor k (List.rev subst) in
	let termtype =
	  let t = it_mkProd_or_LetIn ty_constr ctx' in
	    Evarutil.nf_isevar !evars t
	in
	Evarutil.check_evars env Evd.empty !evars termtype;
	let cst = Declare.declare_internal_constant id
	  (Entries.ParameterEntry (termtype,false), Decl_kinds.IsAssumption Decl_kinds.Logical)
	in instance_hook k None false imps ?hook (ConstRef cst); id
      end
    else
      begin
	let props =
	  match props with
	  | CRecord (loc, _, fs) ->
	      if List.length fs > List.length k.cl_props then
		mismatched_props env' (List.map snd fs) k.cl_props;
	      fs
	  | _ ->
	      if List.length k.cl_props <> 1 then
		errorlabstrm "new_instance" (Pp.str "Expected a definition for the instance body")
	      else [Ident (dummy_loc, Nameops.out_name (pi1 (List.hd k.cl_props))), props]
	in
	let subst =
	  match k.cl_props with
	  | [(na,b,ty)] ->
	      let term = match props with [] -> CHole (Util.dummy_loc, None)
		| [(_,f)] -> f | _ -> assert false in
	      let ty' = substl subst ty in
	      let c = interp_casted_constr_evars evars env' term ty' in
		c :: subst
	  | _ ->
	      let get_id =
		function
		  | Ident id' -> id'
		  | _ -> errorlabstrm "new_instance" (Pp.str "Only local structures are handled")
	        in
	      let props, rest =
		List.fold_left
		  (fun (props, rest) (id,b,_) ->
		    try
		      let (loc_mid, c) = List.find (fun (id', _) -> Name (snd (get_id id')) = id) rest in
		      let rest' = List.filter (fun (id', _) -> Name (snd (get_id id')) <> id) rest in
		      let (loc, mid) = get_id loc_mid in
			Option.iter (fun x -> Dumpglob.add_glob loc (ConstRef x)) (List.assoc mid k.cl_projs);
			c :: props, rest'
		    with Not_found ->
		      (CHole (Util.dummy_loc, None) :: props), rest)
		  ([], props) k.cl_props
	      in
		if rest <> [] then
		  unbound_method env' k.cl_impl (get_id (fst (List.hd rest)))
		else
		  type_ctx_instance evars env' k.cl_props props subst
	in
	let subst = List.fold_left2
	  (fun subst' s (_, b, _) -> if b = None then s :: subst' else subst')
	  [] subst (k.cl_props @ snd k.cl_context)
	in
	let app, ty_constr = instance_constructor k subst in
	let termtype =
	  let t = it_mkProd_or_LetIn ty_constr ctx' in
	    Evarutil.nf_isevar !evars t
	in
	let term = Termops.it_mkLambda_or_LetIn app ctx' in
	evars := Evarutil.nf_evar_defs !evars;
	let term = Evarutil.nf_isevar !evars term in
	let evm = undefined_evars !evars in
	Evarutil.check_evars env Evd.empty !evars termtype;
	  if Evd.is_empty evm then
	    declare_instance_constant k pri global imps ?hook id term termtype
	  else begin
	    evars := Typeclasses.resolve_typeclasses ~onlyargs:true ~fail:true env !evars;
	    let kind = Decl_kinds.Global, Decl_kinds.DefinitionBody Decl_kinds.Instance in
	      Flags.silently (fun () ->
		Command.start_proof id kind termtype (fun _ -> instance_hook k pri global imps ?hook);
		if props <> [] then 
		  Pfedit.by (* (Refiner.tclTHEN (Refiner.tclEVARS ( !isevars)) *)
		    (!refine_ref (evm, term))
		else if Flags.is_auto_intros () then
		  Pfedit.by (Refiner.tclDO len Tactics.intro);
		(match tac with Some tac -> Pfedit.by tac | None -> ())) ();
	      Flags.if_verbose (msg $$ Printer.pr_open_subgoals) ();
	      id
	  end
      end
	
let named_of_rel_context l =
  let acc, ctx =
    List.fold_right
      (fun (na, b, t) (subst, ctx) ->
	let id = match na with Anonymous -> raise (Invalid_argument "named_of_rel_context") | Name id -> id in
	let d = (id, Option.map (substl subst) b, substl subst t) in
	  (mkVar id :: subst, d :: ctx))
      l ([], [])
  in ctx

let push_named_context = List.fold_right push_named

let rec list_filter_map f = function
  | [] -> []
  | hd :: tl -> match f hd with
    | None -> list_filter_map f tl
    | Some x -> x :: list_filter_map f tl

let context ?(hook=fun _ -> ()) l =
  let env = Global.env() in
  let evars = ref Evd.empty in
  let (env', fullctx), impls = interp_context_evars evars env l in
  let fullctx = Evarutil.nf_rel_context_evar !evars fullctx in
  let ce t = Evarutil.check_evars env Evd.empty !evars t in
  List.iter (fun (n, b, t) -> Option.iter ce b; ce t) fullctx;
  let ctx = try named_of_rel_context fullctx with _ ->
    error "Anonymous variables not allowed in contexts."
  in
    List.iter (function (id,_,t) ->
      if Lib.is_modtype () then
	let cst = Declare.declare_internal_constant id
	  (ParameterEntry (t,false), IsAssumption Logical)
	in
	  match class_of_constr t with
	    | Some tc ->
		add_instance (Typeclasses.new_instance tc None false (ConstRef cst));
		hook (ConstRef cst)
	    | None -> ()
      else (
	let impl = List.exists (fun (x,_) ->
	  match x with ExplByPos (_, Some id') -> id = id' | _ -> false) impls
	in
	  Command.declare_one_assumption false (Local (* global *), Definitional) t
	    [] impl (* implicit *) false (* inline *) (dummy_loc, id);
	  match class_of_constr t with
	  | None -> ()
	  | Some tc -> hook (VarRef id)))
      (List.rev ctx)
