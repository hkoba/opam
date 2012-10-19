(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012 OCamlPro                                          *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  OPAM is distributed in the hope that it will be useful,            *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

(* TODO:
   1/ reinstall
   2/ heuristics *)

open OpamTypes

let log fmt = OpamGlobals.log "SOLVER" fmt

let map_action f = function
  | To_change (Some x, y) -> To_change (Some (f x), f y)
  | To_change (None, y)   -> To_change (None, f y)
  | To_delete y           -> To_delete (f y)
  | To_recompile y        -> To_recompile (f y)

let string_of_action action =
  let aux pkg = Printf.sprintf "%s.%d" pkg.Cudf.package pkg.Cudf.version in
  match action with
  | To_change (None, p)   -> Printf.sprintf " - install %s" (aux p)
  | To_change (Some o, p) ->
    let f action =
      Printf.sprintf " - %s %s to %d" action (aux o) p.Cudf.version in
    if compare o.Cudf.version p.Cudf.version < 0 then
      f "upgrade"
    else
      f "downgrade"
  | To_recompile p        -> Printf.sprintf " - recompile %s" (aux p)
  | To_delete p           -> Printf.sprintf " - delete %s" (aux p)

let string_of_actions l =
  OpamMisc.string_of_list string_of_action l

let string_of_package p =
  let installed = if p.Cudf.installed then "installed" else "not-installed" in
  Printf.sprintf "%s.%d(%s)"
    p.Cudf.package
    p.Cudf.version installed

let string_of_packages l =
  OpamMisc.string_of_list string_of_package l

(* Graph of cudf packages *)
module CudfPkg = struct
  type t = Cudf.package
  include Common.CudfAdd
  let to_string = string_of_package
  let string_of_action = string_of_action
end

module CudfActionGraph = MakeActionGraph(CudfPkg)
module CudfMap = OpamMisc.Map.Make(CudfPkg)
module CudfSet = OpamMisc.Set.Make(CudfPkg)

let string_of_atom (p, c) =
  let const = function
    | None       -> ""
    | Some (r,v) -> Printf.sprintf " (%s %d)" (OpamFormula.string_of_relop r) v in
  Printf.sprintf "%s%s" p (const c)

let string_of_request r =
  let to_string = OpamFormula.string_of_conjunction string_of_atom in
  Printf.sprintf "install:%s remove:%s upgrade:%s"
    (to_string r.wish_install)
    (to_string r.wish_remove)
    (to_string r.wish_upgrade)

let map_request f r =
  let f = List.map f in
  { wish_install = f r.wish_install;
    wish_remove  = f r.wish_remove ;
    wish_upgrade = f r.wish_upgrade }

let string_of_cudf_answer l =
  OpamMisc.string_of_list string_of_action  l

let string_of_universe u =
  string_of_packages (Cudf.get_packages u)

let string_of_reason cudf2opam r =
  let open Algo.Diagnostic in
  match r with
  | Conflict (i,j,_) ->
    let nvi = cudf2opam i in
    let nvj = cudf2opam j in
    Printf.sprintf "Conflict between %s and %s."
      (OpamPackage.to_string nvi) (OpamPackage.to_string nvj)
  | Missing (i,_) ->
    let nv = cudf2opam i in
    Printf.sprintf "Missing %s." (OpamPackage.to_string nv)
  | Dependency _ -> ""

let make_chains root depends =
  let open Algo.Diagnostic in
  let d = Hashtbl.create 16 in
  let init = function
    | Dependency (i,_,j) -> List.iter (Hashtbl.add d i) j
    | _ -> () in
  List.iter init depends;
  let rec unroll root =
    match Hashtbl.find_all d root with
    | []       -> [[root]]
    | children ->
      let chains = List.flatten (List.map unroll children) in
      if root.Cudf.package = "dummy" || root.Cudf.package = "dose-dummy-request" then
        chains
      else
        List.map (fun cs -> root :: cs) chains in
  List.filter (function [x] -> false | _ -> true) (unroll root)

exception Found of Cudf.package

let string_of_reasons cudf2opam reasons =
  let open Algo.Diagnostic in
  let depends, reasons = List.partition (function Dependency _ -> true | _ -> false) reasons in
  let root =
    try List.iter (function Dependency (p,_,_) -> raise (Found p) | _ -> ()) depends; assert false
    with Found p -> p in
  let chains = make_chains root depends in
  let rec string_of_chain = function
    | []   -> ""
    | [p]  -> OpamPackage.to_string (cudf2opam p)
    | p::t -> Printf.sprintf "%s <- %s" (OpamPackage.to_string (cudf2opam p)) (string_of_chain t) in
  let b = Buffer.create 1024 in
  let string_of_chain c = string_of_chain (List.rev c) in
  List.iter (fun r ->
    Printf.bprintf b " - %s\n" (string_of_reason cudf2opam r)
  ) reasons;
  List.iter (fun c ->
    Printf.bprintf b " + %s\n" (string_of_chain c)
  ) chains;
  Buffer.contents b

(* Convert an OPAM formula into a debian formula *)
let atom2debian (n, v) =
  (OpamPackage.Name.to_string n, None),
  match v with
  | None       -> None
  | Some (r,v) -> Some (OpamFormula.string_of_relop r, OpamPackage.Version.to_string v)

(* to convert to cudf *)
(* see [Debcudf.add_inst] for more details about the format *)
let s_status = "status"
let s_installed   = "  installed"

(* Convert an OPAM package to a debian package *)
let opam2debian universe depopts package =
  let depends = OpamPackage.Map.find package universe.u_depends in
  let depends =
    if depopts
    then And (depends, OpamPackage.Map.find package universe.u_depopts)
    else depends in
  let conflicts = OpamPackage.Map.find package universe.u_conflicts in
  let installed =
    OpamPackage.Set.mem package universe.u_installed &&
    match universe.u_action with
    | Upgrade reinstall -> not (OpamPackage.Set.mem package reinstall)
    | _                 -> true in
  let open Debian.Packages in
  { Debian.Packages.default_package with
    name      = OpamPackage.Name.to_string (OpamPackage.name package) ;
    version   = OpamPackage.Version.to_string (OpamPackage.version package);
    depends   = List.map (List.map atom2debian) (OpamFormula.to_cnf depends);
    conflicts = List.map atom2debian (OpamFormula.to_conjunction conflicts);
    extras    =
      if installed then
        (s_status, s_installed) :: Debian.Packages.default_package.extras
      else
        Debian.Packages.default_package.extras }

(* Convert an debian package to a CUDF package *)
let debian2cudf tables package =
  Debian.Debcudf.tocudf tables package

let atom2cudf opam2cudf (n, v) : Cudf_types.vpkg =
  Common.CudfAdd.encode (OpamPackage.Name.to_string n),
  match v with
  | None       -> None
  | Some (r,v) ->
    let pkg =
      try opam2cudf (OpamPackage.create n v)
      with Not_found ->
        OpamGlobals.error_and_exit "Package %s does not have a version %s"
          (OpamPackage.Name.to_string n)
          (OpamPackage.Version.to_string v) in
    Some (r, pkg.Cudf.version)

(* load a cudf universe from an opam one *)
let load_cudf_universe ?(depopts=false) universe =
  let opam2debian =
    OpamPackage.Set.fold
      (fun pkg map -> OpamPackage.Map.add pkg (opam2debian universe depopts pkg) map)
      universe.u_available
      OpamPackage.Map.empty in
  let tables = Debian.Debcudf.init_tables (OpamPackage.Map.values opam2debian) in
  let opam2cudf = OpamPackage.Map.map (debian2cudf tables) opam2debian in
  let cudf2opam = Hashtbl.create 1024 in
  OpamPackage.Map.iter (fun opam cudf -> Hashtbl.add cudf2opam (cudf.Cudf.package,cudf.Cudf.version) opam) opam2cudf;
  let universe = Cudf.load_universe (OpamPackage.Map.values opam2cudf) in
  (fun opam ->
    try OpamPackage.Map.find opam opam2cudf
    with Not_found ->
      OpamGlobals.error_and_exit "Cannot find %s" (OpamPackage.to_string opam)),
  (fun cudf ->
    try Hashtbl.find cudf2opam (cudf.Cudf.package,cudf.Cudf.version)
    with Not_found ->
      OpamGlobals.error_and_exit "Cannot find %s.%d" cudf.Cudf.package cudf.Cudf.version),
  universe

(* Graph of cudf packages *)
module CudfGraph = struct

  module PG = struct
    module G = Algo.Defaultgraphs.PackageGraph.G
    let union g1 g2 =
      let g1 = G.copy g1 in
      let () =
        begin
          G.iter_vertex (G.add_vertex g1) g2;
          G.iter_edges (G.add_edge g1) g2;
        end in
      g1
    include G
    let succ g v =
      try succ g v
      with _ -> []
  end

  module PO = Algo.Defaultgraphs.GraphOper (PG)

  module type FS = sig
    type iterator
    val start : PG.t -> iterator
    val step : iterator -> iterator
    val get : iterator -> PG.V.t
  end

  module Make_fs (F : FS) = struct
    let fold f acc g =
      let rec aux acc iter =
        match try Some (F.get iter, F.step iter) with Exit -> None with
        | None -> acc
        | Some (x, iter) -> aux (f acc x) iter in
      aux acc (F.start g)
  end

  module PG_topo = Graph.Topological.Make (PG)

  let dep_reduction u =
    let g = Algo.Defaultgraphs.PackageGraph.dependency_graph u in
    PO.transitive_reduction g;
    g

  let output g filename =
    if !OpamGlobals.debug then (
      let fd = open_out (filename ^ ".dot") in
      Algo.Defaultgraphs.PackageGraph.DotPrinter.output_graph fd g;
      close_out fd
    )

  (* Return a topoligal sort of the closures of pkgs in g *)
  let topo_closure g pkgs =
    let _, l =
      PG_topo.fold
        (fun pkg (closure, topo) ->
          if CudfSet.mem pkg closure then
            CudfSet.union closure (CudfSet.of_list (PG.succ g pkg)),
            pkg :: topo
          else
            closure, topo)
        g
        (pkgs, []) in
    l

end

let to_cudf univ req = (
  Cudf.default_preamble,
  univ,
  { Cudf.request_id = "opam";
    install    = req.wish_install;
    remove     = req.wish_remove;
    upgrade    = req.wish_upgrade;
    req_extra  = [] }
)

(* Return the universe in which the system has to go *)
let get_final_universe univ req =
  let open Algo.Depsolver in
  log "get_final_universe universe=%s" (string_of_universe univ);
  log "get_final_universe request=%s" (string_of_request req);
  match Algo.Depsolver.check_request ~explain:true (to_cudf univ req) with
  | Sat (_,u) -> Success u
  | Error str -> OpamGlobals.error_and_exit "solver error: str"
  | Unsat r   ->
    let open Algo.Diagnostic in
    match r with
    | Some {result=Failure f} -> Conflicts f
    | _                       -> failwith "opamSolver"


(* Transform a diff from current to final state into a list of
   actions *)
let actions_of_diff diff =
  Hashtbl.fold (fun pkgname s acc ->
    let add x = x :: acc in
    let removed =
      try Some (Common.CudfAdd.Cudf_set.choose s.Common.CudfDiff.removed)
      with Not_found -> None in
    let installed =
      try Some (Common.CudfAdd.Cudf_set.choose s.Common.CudfDiff.installed)
      with Not_found -> None in
    match removed, installed with
    | None      , Some p     -> add (To_change (None, p))
    | Some p    , None       -> add (To_delete p)
    | Some p_old, Some p_new -> add (To_change (Some p_old, p_new))
    | None      , None       -> acc
  ) diff []

let cudf_resolve univ req =
  let open Algo in
  match get_final_universe univ req with
  | Conflicts e -> Conflicts e
  | Success final_universe ->
    log "cudf_resolve success=%s" (string_of_universe final_universe);
    try
      let diff = Common.CudfDiff.diff univ final_universe in
      Success (actions_of_diff diff)
    with Cudf.Constraint_violation s ->
      OpamGlobals.error_and_exit "constraint violations: %s" s

let output_universe name universe =
  if !OpamGlobals.debug then (
    let oc = open_out (name ^ ".cudf") in
    Cudf_printer.pp_universe oc universe;
    close_out oc;
    let g = CudfGraph.dep_reduction universe in
    CudfGraph.output g name;
  )

let create_graph filter universe =
  let pkgs = Cudf.get_packages ~filter universe in
  let u = Cudf.load_universe pkgs in
  CudfGraph.dep_reduction u

(* Build the graph of actions.
   - [simple_universe] is the graph with 'depends' only
   - [complex_universe] is the graph with 'depends' + 'depopts' *)
let solution_of_actions ~simple_universe ~complete_universe actions =
  log "graph_of_actions actions=%s" (string_of_actions actions);

  (* The packages to remove or upgrade *)
  let to_remove_or_upgrade =
    OpamMisc.filter_map (function
      | To_change (Some pkg, _)
      | To_delete pkg -> Some pkg
      | _ -> None
    ) actions in

  (* the packages to remove *)
  let to_remove =
    CudfSet.of_list (OpamMisc.filter_map (function
      | To_delete pkg -> Some pkg
      | _ -> None
    ) actions) in

  (* the packages to recompile *)
  let to_recompile =
    CudfSet.of_list (OpamMisc.filter_map (function
      | To_recompile pkg -> Some pkg
      | _ -> None
    ) actions) in

  (* compute initial packages to install *)
  let to_process_init =
    CudfMap.of_list (OpamMisc.filter_map (function
      | To_recompile pkg
      | To_change (_, pkg) as act -> Some (pkg, act)
      | To_delete _ -> None
    ) actions) in

  let complete_graph =
    let g =
      CudfGraph.PO.O.mirror
        (create_graph (fun p -> p.Cudf.installed || CudfMap.mem p to_process_init) complete_universe) in
    List.iter (CudfGraph.PG.remove_vertex g) to_remove_or_upgrade;
    g in

  (* compute packages to recompile due to the REMOVAL of packages *)
  let to_recompile =
    CudfSet.fold (fun pkg to_recompile ->
      let succ = CudfGraph.PG.succ complete_graph pkg in
      CudfSet.union to_recompile (CudfSet.of_list succ)
    ) to_remove to_recompile in

  let to_remove =
    CudfGraph.topo_closure (create_graph (fun p -> CudfSet.mem p to_remove) simple_universe) to_remove in

  (* compute packages to recompile and to process due to NEW packages *)
  let to_recompile, to_process_map =
    CudfGraph.PG_topo.fold
      (fun pkg (to_recompile, to_process_map) ->
        let add_succ pkg action =
          (CudfSet.union to_recompile (CudfSet.of_list (CudfGraph.PG.succ complete_graph pkg)),
           CudfMap.add pkg action (CudfMap.remove pkg to_process_map)) in
        if CudfMap.mem pkg to_process_init then
          add_succ pkg (CudfMap.find pkg to_process_init)
        else if CudfSet.mem pkg to_recompile then
          add_succ pkg (To_recompile pkg)
        else
          to_recompile, to_process_map)
      complete_graph
      (to_recompile, CudfMap.empty) in

  (* construct the answer [graph] to add.
     Then, it suffices to fold it topologically
     by following the action given at each node (install or recompile). *)
  let to_process = CudfActionGraph.create () in
  CudfMap.iter (fun _ act -> CudfActionGraph.add_vertex to_process act) to_process_map;
  CudfGraph.PG.iter_edges
    (fun v1 v2 ->
      try
        let v1 = CudfMap.find v1 to_process_map in
        let v2 = CudfMap.find v2 to_process_map in
        CudfActionGraph.add_edge to_process v1 v2
      with Not_found ->
        ())
    complete_graph;
  { CudfActionGraph.to_remove; to_process }


(******************************************************************************)

let string_of_request r =
  let to_string = OpamFormula.string_of_conjunction OpamFormula.string_of_atom in
  Printf.sprintf "install:%s remove:%s upgrade:%s"
    (to_string r.wish_install)
    (to_string r.wish_remove)
    (to_string r.wish_upgrade)

let opam_graph cudf2opam cudf_graph =
  let size = CudfActionGraph.nb_vertex cudf_graph in
  let opam_graph = PackageActionGraph.create ~size () in
  CudfActionGraph.iter_vertex (fun package ->
    PackageActionGraph.add_vertex opam_graph (map_action cudf2opam package)

  ) cudf_graph;
  CudfActionGraph.iter_edges (fun p1 p2 ->
    PackageActionGraph.add_edge opam_graph
      (map_action cudf2opam p1)
      (map_action cudf2opam p2)
  ) cudf_graph;
  opam_graph

let opam_solution cudf2opam cudf_solution =
  let to_remove = List.map cudf2opam cudf_solution.CudfActionGraph.to_remove in
  let to_process = opam_graph cudf2opam cudf_solution.CudfActionGraph.to_process in
  { PackageActionGraph.to_remove ; to_process }

let resolve universe request =
  log "resolve universe=%s" (OpamPackage.Set.to_string universe.u_available);
  log "resolve request=%s" (string_of_request request);
  let opam2cudf, cudf2opam, simple_universe = load_cudf_universe universe in
  let cudf_request = map_request (atom2cudf opam2cudf) request in
  match cudf_resolve simple_universe cudf_request with
  | Conflicts c     -> Conflicts (fun () -> string_of_reasons cudf2opam (c ()))
  | Success actions ->
    let _, _, complete_universe = load_cudf_universe ~depopts:true universe in
    let solution = solution_of_actions ~simple_universe ~complete_universe actions in
    Success (opam_solution cudf2opam solution)

let filter_dependencies f_direction ~depopts ~installed universe packages =
  log "filter_dependencies packages=%s" (OpamPackage.Set.to_string packages);
  let opam2cudf, cudf2opam, cudf_universe = load_cudf_universe ~depopts universe in
  let cudf_packages = List.map opam2cudf (OpamPackage.Set.elements packages) in
  let graph = f_direction (CudfGraph.dep_reduction cudf_universe) in
  let packages_topo = CudfGraph.topo_closure graph (CudfSet.of_list cudf_packages) in
  let list = List.map cudf2opam packages_topo in
  if installed then
    List.filter (fun nv -> OpamPackage.Set.mem nv universe.u_installed) list
  else
    list

let get_backward_dependencies = filter_dependencies (fun x -> x)

let get_forward_dependencies = filter_dependencies CudfGraph.PO.O.mirror

let delete_or_update t =
  t.PackageActionGraph.to_remove <> [] ||
  PackageActionGraph.fold_vertex
    (fun v acc ->
      acc || match v with To_change (Some _, _) -> true | _ -> false)
    t.PackageActionGraph.to_process
    false

let stats sol =
  let s_install, s_reinstall, s_upgrade, s_downgrade =
    PackageActionGraph.fold_vertex (fun action (i,r,u,d) ->
      match action with
      | To_change (None, _)             -> i+1, r, u, d
      | To_change (Some x, y) when x<>y ->
        if OpamPackage.Version.compare (OpamPackage.version x) (OpamPackage.version y) < 0 then
          i, r, u+1, d
        else
          i, r, u, d+1
      | To_change (Some _, _)
      | To_recompile _                  -> i, r+1, u, d
      | To_delete _ -> assert false)
      sol.PackageActionGraph.to_process
      (0, 0, 0, 0) in
  let s_remove = List.length sol.PackageActionGraph.to_remove in
  { s_install; s_reinstall; s_upgrade; s_downgrade; s_remove }

let string_of_stats stats =
  Printf.sprintf "%d to install | %d to reinstall | %d to upgrade | %d to downgrade | %d to remove"
    stats.s_install
    stats.s_reinstall
    stats.s_upgrade
    stats.s_downgrade
    stats.s_remove

let solution_is_empty t =
  t.PackageActionGraph.to_remove = [] && PackageActionGraph.is_empty t.PackageActionGraph.to_process

let print_solution t =
  if solution_is_empty t then
    ()
  (*Globals.msg
    "No actions will be performed, the current state satisfies the request.\n"*)
  else
    let f = OpamPackage.to_string in
    List.iter (fun p -> OpamGlobals.msg " - remove %s\n" (f p)) t.PackageActionGraph.to_remove;
    PackageActionGraph.Topological.iter
      (function action -> OpamGlobals.msg "%s\n" (PackageAction.string_of_action action))
      t.PackageActionGraph.to_process