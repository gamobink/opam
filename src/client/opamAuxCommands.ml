(**************************************************************************)
(*                                                                        *)
(*    Copyright 2017 OCamlPro                                             *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamStateTypes

let log fmt = OpamConsole.log "AUXCMD" fmt
let slog = OpamConsole.slog

let package_file_changes st packages =
  OpamPackage.Set.fold (fun nv acc ->
      let f =
        OpamPath.Switch.changes st.switch_global.root st.switch nv.name
      in
      match OpamFile.Changes.read_opt f with
      | None -> acc
      | Some ch -> OpamStd.String.Map.union (fun _ x -> x) acc ch)
    packages
    OpamStd.String.Map.empty

let copy_files_to_destdir st pfx packages =
  let switch_pfx = OpamPath.Switch.root st.switch_global.root st.switch in
  package_file_changes st packages |>
  OpamDirTrack.check switch_pfx |>
  List.iter @@ function
  | src, `Unchanged ->
    let relf = OpamFilename.remove_prefix switch_pfx src in
    let dst = OpamFilename.Op.(pfx // relf) in
    OpamConsole.msg "%-40s %s %s\n"
      relf (OpamConsole.colorise `blue "=>")
      (OpamFilename.to_string dst);
    if not OpamStateConfig.(!r.dryrun) then
      if OpamFilename.exists src then OpamFilename.copy ~src ~dst else
      let as_dir f = OpamFilename.(Dir.of_string (to_string f)) in
      if OpamFilename.exists_dir (as_dir src)
      then OpamFilename.mkdir (as_dir dst)
  | src, (`Changed | `Removed as ch) ->
    OpamConsole.warning "Not installing %s, which was %s since"
      (OpamConsole.colorise `bold (OpamFilename.to_string src))
      (match ch with `Changed -> "changed" | `Removed -> "removed")

let remove_files_from_destdir st pfx packages =
  package_file_changes st packages |>
  OpamStd.String.Map.bindings |>
  List.rev |> (* Get the longer names first, their parent folders last *)
  List.iter @@ fun (rel_file, change) ->
  match change with
  | OpamDirTrack.Added _
  | OpamDirTrack.Contents_changed _
  | OpamDirTrack.Kind_changed _ ->
    let f = OpamFilename.Op.(pfx // rel_file) in
    let d = OpamFilename.Op.(pfx / rel_file) in
    if OpamFilename.exists f then
      (OpamConsole.msg "Removing %s\n"
         (OpamConsole.colorise `bold (OpamFilename.to_string f));
       if not OpamStateConfig.(!r.dryrun) then OpamFilename.remove f)
    else if OpamFilename.exists_dir d then
      if OpamFilename.dir_is_empty d then
        (OpamConsole.msg "Removing %s\n"
           (OpamConsole.colorise `bold (OpamFilename.Dir.to_string d));
         if not OpamStateConfig.(!r.dryrun) then OpamFilename.rmdir d)
      else
        OpamConsole.note "Not removing non-empty directory %s"
          (OpamConsole.colorise `bold (OpamFilename.Dir.to_string d))
  | _ -> ()

let name_from_project_dirname d =
  try
    Some (OpamFilename.(Base.to_string (basename_dir d)) |>
          Re.(replace_string (compile (seq [char '.'; any]))) ~by:"" |>
          OpamPackage.Name.of_string)
  with Failure _ -> None

let url_with_local_branch = function
  | { OpamUrl.backend = #OpamUrl.version_control; hash = None; _ } as url ->
    (match OpamProcess.Job.run (OpamRepository.current_branch url) with
     | Some b -> { url with OpamUrl.hash = Some b }
     | None -> url)
  | url -> url

let resolve_locals atom_or_local_list =
  let open OpamStd.Option.Op in
  let target_dir dir =
    let d = OpamFilename.Dir.to_string dir in
    let backend = OpamUrl.guess_version_control d in
    OpamUrl.parse ?backend d |>
    url_with_local_branch
  in
  let to_pin, atoms =
    List.fold_left (fun (to_pin, atoms) -> function
        | `Atom a -> to_pin, a :: atoms
        | `Dirname d ->
          let files = OpamPinned.files_in_source d in
          let target = target_dir d in
          List.fold_left (fun (to_pin, atoms) (n, f) ->
              let name =
                n >>+ fun () ->
                OpamFile.OPAM.(name_opt (safe_read f))
                >>+ fun () ->
                match files with
                | [] | _::_::_ -> None
                | [_] -> name_from_project_dirname d
              in
              match name with
              | Some n ->
                (n, target, f) :: to_pin, (n, None) :: atoms
              | None ->
                OpamConsole.warning
                  "Ignoring file at %s: could not infer package name"
                  (OpamFile.to_string f);
                to_pin, atoms)
            (to_pin, atoms) files
        | `Filename f ->
          let srcdir = OpamFilename.dirname f in
          let srcdir =
            if OpamFilename.dir_ends_with ".opam" srcdir &&
               OpamUrl.guess_version_control (OpamFilename.Dir.to_string srcdir)
               = None
            then OpamFilename.dirname_dir srcdir
            else srcdir
          in
          let name =
            OpamPinned.name_of_opam_filename srcdir f >>+ fun () ->
            OpamFile.OPAM.(name_opt (safe_read (OpamFile.make f))) >>+ fun () ->
            name_from_project_dirname srcdir
          in
          match name with
          | Some n ->
            (n, target_dir srcdir, OpamFile.make f) :: to_pin,
            (n, None) :: atoms
          | None ->
            OpamConsole.error_and_exit
              "Could not infer package name from package definition file %s"
              (OpamFilename.to_string f))
      ([], [])
      atom_or_local_list
  in
  let duplicates =
    List.filter (fun (n, _, f) ->
        List.exists (fun (n1, _, f1) -> n = n1 && f <> f1) to_pin)
      to_pin
  in
  match duplicates with
  | [] -> List.rev to_pin, List.rev atoms
  | _ ->
    OpamConsole.error_and_exit
      "Multiple files for the same package name were specified:\n%s"
      (OpamStd.Format.itemize (fun (n, t, f) ->
         Printf.sprintf "Package %s with definition %s %s %s"
           (OpamConsole.colorise `bold @@ OpamPackage.Name.to_string n)
           (OpamFile.to_string f)
           (OpamConsole.colorise `blue "=>")
           (OpamUrl.to_string t))
          duplicates)

let autopin st ?(simulate=false) atom_or_local_list =
  let to_pin, atoms = resolve_locals atom_or_local_list in
  if to_pin = [] then st, atoms else
  let pinning_dirs =
    OpamStd.List.filter_map (function
        | `Dirname d -> Some d
        | _ -> None)
      atom_or_local_list
  in
  log "autopin: %a"
    (slog @@ OpamStd.List.to_string (fun (name, target, _) ->
         Printf.sprintf "%s => %s"
           (OpamPackage.Name.to_string name)
           (OpamUrl.to_string target)))
    to_pin;
  let obsolete_pins =
    (* Packages not current but pinned to the same dirs *)
    OpamPackage.Set.filter (fun nv ->
        not (List.exists (fun (n,_,_) -> n = nv.name) to_pin) &&
        match OpamStd.Option.Op.(OpamSwitchState.primary_url st nv >>=
                                 OpamUrl.local_dir)
        with
        | Some d -> List.mem d pinning_dirs
        | None -> false)
      st.pinned
  in
  let st =
    if simulate || OpamStateConfig.(!r.dryrun) || OpamClientConfig.(!r.show)
    then
      OpamPackage.Set.fold (fun nv st -> OpamPinCommand.unpin_one st nv)
        obsolete_pins st
    else
      OpamPinCommand.unpin st
        (OpamPackage.Name.Set.elements
           (OpamPackage.names_of_packages obsolete_pins))
  in
  let already_pinned, to_pin =
    List.partition (fun (name, target, _) ->
        try
          OpamSwitchState.primary_url st (OpamPinned.package st name)
          = Some target
        with Not_found -> false)
      to_pin
  in
  let already_pinned_set =
    List.fold_left (fun acc (name, _, _) ->
        OpamPackage.Set.add (OpamPinned.package st name) acc)
      OpamPackage.Set.empty already_pinned
  in
  let st =
    if OpamStateConfig.(!r.dryrun) || OpamClientConfig.(!r.show) then st else
    let working_dir =
      if OpamClientConfig.(!r.working_dir) then already_pinned_set
      else OpamPackage.Set.empty
    in
    let _result, st, _updated =
      OpamUpdate.dev_packages st ~working_dir already_pinned_set
    in
    st
  in
  let st, pins =
    if simulate || OpamStateConfig.(!r.dryrun) || OpamClientConfig.(!r.show)
    then
      let local_names =
        List.fold_left (fun set (name, _, _) ->
            OpamPackage.Name.Set.add name set)
          OpamPackage.Name.Set.empty to_pin
      in
      let local_opams =
        List.fold_left (fun map (name, target, file) ->
            match
              OpamPinCommand.read_opam_file_for_pinning name file target
            with
            | None -> map
            | Some opam ->
              let opam =
                opam |>
                OpamFile.OPAM.with_name name |>
                OpamFile.OPAM.with_url (OpamFile.URL.create target)
              in
              let opam, version = match OpamFile.OPAM.version_opt opam with
                | Some v -> opam, v
                | None ->
                  let v = OpamPackage.Version.of_string "~dev" in
                  OpamFile.OPAM.with_version v opam, v
              in
              OpamPackage.Map.add (OpamPackage.create name version) opam map)
          OpamPackage.Map.empty to_pin
      in
      let local_packages = OpamPackage.keys local_opams in
      let st = {
        st with
        opams =
          OpamPackage.Map.union (fun _ o -> o) st.opams local_opams;
        packages =
          OpamPackage.Set.union st.packages local_packages;
        available_packages = lazy (
          OpamPackage.Set.union
            (OpamPackage.Set.filter
               (fun nv -> OpamPackage.Name.Set.mem nv.name local_names)
               (Lazy.force st.available_packages))
            (OpamSwitchState.compute_available_packages
               st.switch_global st.switch st.switch_config ~pinned:st.pinned
               ~opams:local_opams)
        );
      } in
      st, local_packages
    else
    try
      List.fold_left (fun (st, pins) (name, target, file) ->
          match OpamPinCommand.read_opam_file_for_pinning name file target with
          | None -> st, pins
          | Some opam ->
            let st =
              try
                OpamPinCommand.source_pin st name ~quiet:true ~opam
                  (Some target)
              with OpamPinCommand.Nothing_to_do -> st
            in
            st, OpamPackage.Set.add (OpamPinned.package st name) pins)
        (st, OpamPackage.Set.empty) to_pin
    with OpamPinCommand.Aborted -> OpamConsole.error_and_exit "Aborted"
  in
  let pins = OpamPackage.Set.union pins already_pinned_set in
  let atoms =
    List.map (function
        | (_, Some _) as at -> at
        | name, None ->
          name,
          OpamStd.Option.map
            (fun nv -> `Eq, nv.version)
            (OpamPackage.package_of_name_opt pins name))
      atoms
  in
  st, atoms
