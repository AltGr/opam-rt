(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open OpamTypes
open OpamFilename.OP

let seed_ref =
  ref 1664

let set_seed seed =
  seed_ref := seed

let seed () =
  !seed_ref

module Color = struct

  let red fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[31m%s\027[m" s) fmt

  let green fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[32m%s\027[m" s) fmt

  let yellow fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[33m%s\027[m" s) fmt

end

module Git = struct

  let exec repo command =
    OpamFilename.in_dir repo (fun () ->
        OpamSystem.command command
      )

  let return_one_line repo command =
    OpamFilename.in_dir repo (fun () ->
        List.hd (OpamSystem.read_command_output command)
      )

  let return repo command =
    OpamFilename.in_dir repo (fun () ->
        (OpamSystem.read_command_output command)
      )

  let commit repo fmt =
    Printf.kprintf (fun msg ->
        exec repo [ "git"; "commit"; "-a"; "-m"; msg; "--allow-empty" ]
      ) fmt

  let commit_file repo file fmt =
    Printf.kprintf (fun msg ->
        let file = OpamFilename.remove_prefix repo file in
        exec repo [ "git"; "commit"; "-m"; msg; "--allow-empty"; file ]
      ) fmt

  let revision repo =
    return_one_line repo [ "git"; "rev-parse"; "HEAD" ]

  let commits repo =
    return repo ["git"; "log"; "master"; "--pretty=format:%H"]

  let init repo =
    exec repo ["git"; "init"]

  let test_tag = "test"

  let branch repo =
    exec repo ["git"; "checkout"; "-B"; test_tag]

  let add repo file =
    if OpamFilename.exists file then
      let file = OpamFilename.remove_prefix repo file in
      exec repo ["git"; "add"; file]

  let checkout repo hash =
    exec repo ["git"; "checkout"; hash];
    exec repo ["git"; "clean"; "-fdx"]

end

module Contents = struct

  let log = OpamGlobals.log "CONTENTS"

  type t = (basename * string) list

  let base = OpamFilename.Base.of_string

  let random_string n =
    let s = String.create n in
    String.iteri (fun i _ ->
        let c = int_of_char 'A' + Random.int 58 in
        s.[i] <- char_of_int c
      ) s;
    s

  let files () = [
    base "a/a", random_string 10;
    base "a/b", random_string 20;
    base "b"  , random_string 20;
  ]

  let install name =
    base (OpamPackage.Name.to_string name ^ ".install"),
    "lib: [ \"a/a\" \"a/b\" ]\n\
     bin: [ \"b\" ]\n"

  let create nv =
    List.sort compare (install (OpamPackage.name nv) :: files ())

  let root repo nv =
    OpamFilename.dirname_dir repo.repo_root / "contents" / OpamPackage.to_string nv

  let read repo nv =
    log "read %s" (OpamPackage.to_string nv);
    let root = root repo nv in
    let files = OpamFilename.rec_files root in
    let files = List.map (fun file ->
        let base = base (OpamFilename.remove_prefix root file) in
        let content = OpamFilename.read file in
        base, content
      ) files in
    List.sort compare files

  let write repo nv t =
    log "write %s" (OpamPackage.to_string nv);
    let root = root repo nv in
    if not (OpamFilename.exists_dir root) then (
      OpamFilename.mkdir root;
      Git.init root;
    );
    List.iter (fun (base, contents) ->
        let file = OpamFilename.create root base in
        OpamFilename.write file contents
      ) t;
    Git.commit root "Add new content for package %s" (OpamPackage.to_string nv)

end

module Packages = struct

  let log = OpamGlobals.log "PACKAGES"

  open OpamFile

  type t = {
    nv      : package;
    prefix  : string option;
    opam    : OPAM.t;
    url     : URL.t option;
    descr   : Descr.t option;
    contents: (basename * string) list;
    archive : string option;
  }

  let opam nv seed =
    let opam = OPAM.create nv in
    let maintainer = "test-" ^ string_of_int seed in
    OPAM.with_maintainer opam maintainer

  let url kind path = function
    | 0 -> None
    | i ->
      let path = match kind with
        | Some `git   -> (OpamFilename.Dir.to_string path, Some Git.test_tag)
        | None
        | Some `local -> (OpamFilename.Dir.to_string path, None)
        | _           -> failwith "TODO" in
      let url = URL.create kind path in
      let checksum = Printf.sprintf "checksum-%d" i in
      Some (URL.with_checksum url checksum)

  let descr = function
    | 0 -> None
    | i -> Some (Descr.of_string (Printf.sprintf "This is a very nice package (%d)!" i))

  let archive contents nv seed =
    match seed with
    | 0
    | 1
    | 3 -> None
    | _ ->
      let tmp_file = Filename.temp_file (OpamPackage.to_string nv) "archive" in
      log "Creating an archive file in %s" tmp_file;
      OpamFilename.with_tmp_dir (fun root ->
          let dir = root / OpamPackage.to_string nv in
          List.iter (fun (base, contents) ->
              let file = OpamFilename.create dir base in
              OpamFilename.write file contents
            ) contents;
          OpamFilename.exec root [
            ["tar"; "czf"; tmp_file; OpamPackage.to_string nv]
          ];
          let contents = OpamSystem.read tmp_file in
          OpamSystem.remove tmp_file;
          Some contents
        )

  let prefix nv =
    match OpamPackage.Version.to_string (OpamPackage.version nv) with
    | "1" -> None
    | _   ->
      let name = OpamPackage.Name.to_string (OpamPackage.name nv) in
      Some (Printf.sprintf "prefix-%s" name)

  let files repo prefix nv =
    let opam = OpamPath.Repository.opam repo prefix nv in
    let descr = OpamPath.Repository.descr repo prefix nv in
    let url = OpamPath.Repository.url repo prefix nv in
    let archive = OpamPath.Repository.archive repo nv in
    opam, descr, url, archive

  let files_of_t repo t =
    files repo t.prefix t.nv

  let write_o f = function
    | None   -> ()
    | Some x -> f x

  let write repo t =
    let opam, descr, url, archive = files_of_t repo t in
    OPAM.write opam t.opam;
    write_o (Descr.write descr) t.descr;
    write_o (URL.write url) t.url;
    write_o (OpamFilename.write archive) t.archive;
    Contents.write repo t.nv t.contents

  let read_o f file =
    if OpamFilename.exists file then Some (f file)
    else None

  let read repo prefix nv =
    let opam, descr, url, archive = files repo prefix nv in
    let opam = OPAM.read opam in
    let descr = read_o Descr.read descr in
    let url = read_o URL.read url in
    let contents = Contents.read repo nv in
    let archive = read_o OpamFilename.read archive in
    { nv; prefix; opam; descr; url; contents; archive }

  let add repo t =
    write repo t;
    let opam, descr, url, archive = files_of_t repo t in
    let commit file =
      if OpamFilename.exists file then (
        Git.add repo.repo_root file;
        Git.commit_file repo.repo_root file
          "Add package %s (%s)"
          (OpamPackage.to_string t.nv) (OpamFilename.to_string file);
        Some (Git.revision repo.repo_root, file);
      ) else
        None in
    let commits = OpamMisc.filter_map commit [opam; descr; url; archive] in
    (t.nv, commits)

end

module OPAM = struct

  let opam opam_root command args =
    let debug = if !OpamGlobals.debug then ["--debug"] else [] in
    OpamSystem.command
      ("opam" :: command ::
         ["--root"; (OpamFilename.Dir.to_string opam_root)]
         @ debug
         @ args)

  let init opam_root repo =
    let kind = string_of_repository_kind repo.repo_kind in
    OpamGlobals.sync_archives := true;
    opam opam_root "init" [
      OpamRepositoryName.to_string repo.repo_name;
      string_of_address repo.repo_address;
      "--no-setup"; "--no-base-packages";
      "--kind"; kind
    ]

  let install opam_root package =
    opam opam_root "install" [OpamPackage.to_string package]

  let update opam_root =
    opam opam_root "update" ["--sync-archives"]

end

module Check = struct

  module A = OpamFilename.Attribute

  type error = {
    source: string;
    attr  : file_attribute;
    file  : filename;
  }

  exception Sync_errors of error list

  let sync_errors errors =
    OpamGlobals.error "\n%s" (Color.red " -- Sync error --");
    List.iter (fun { source; attr; file } ->
        OpamGlobals.error "%s: %s\n%s\n%s\n"
          source
          (A.to_string attr) (OpamFilename.to_string file) (OpamFilename.read file)
      ) errors;
    raise (Sync_errors errors)

  let set map =
    A.Map.fold (fun a _ set -> A.Set.add a set) map A.Set.empty

  exception Found of file_attribute * filename

  let find_binding fn map =
    try A.Map.iter (fun a f -> if fn a f then raise (Found (a,f))) map; raise Not_found
    with Found (a,f) -> (a,f)

  let archives repo root =
    let archives_repo = OpamPath.Repository.archives_dir repo in
    let archives_opam = OpamPath.archives_dir root in
    let attributes dir =
      let files = OpamFilename.files dir in
      List.fold_left (fun attrs file ->
          A.Map.add (OpamFilename.to_attribute dir file) file attrs
        ) A.Map.empty files in
    let attrs_repo = attributes archives_repo in
    let attrs_opam = attributes archives_opam in
    let check (s1, m1) (s2, m2) =
      A.Map.fold (fun a1 f1 errors ->
          let same_base a2 _ = (A.base a1 = A.base a2) in
          if A.Map.exists same_base m2 then
            if A.Map.mem a1 m2 then errors
            else
              { source = s1; attr = a1; file = f1 }
              :: errors
          else
            errors
        ) m1 [] in

    let errors =
      let opam = ("opam", attrs_opam) in
      let repo = ("repository", attrs_repo) in
      check opam repo @ check repo opam in

    if errors <> [] then
      sync_errors errors

  let packages repo root =
    let packages_repo = OpamPath.Repository.packages_dir repo in
    let packages_opam = OpamPath.packages_dir root in
    let attributes dir =
      let all = OpamFilename.rec_files dir in
      let files = List.filter (fun f ->
          OpamFilename.ends_with "opam" f
          || OpamFilename.ends_with "url" f
          || OpamFilename.ends_with "descr" f
          (* XXX: deal with archive files *)
        ) all in
      List.fold_left (fun attrs f ->
          let root = OpamFilename.dirname_dir (OpamFilename.dirname f) in
          let attr = OpamFilename.to_attribute root f in
          A.Map.add attr f attrs
        ) A.Map.empty files in

    let attrs_repo = attributes packages_repo in
    let attrs_opam = attributes packages_opam in

    let attrs_repo_s = set attrs_repo in
    let attrs_opam_s = set attrs_opam in

    let diff1 = A.Set.diff attrs_repo_s attrs_opam_s in
    let diff2 = A.Set.diff attrs_opam_s attrs_repo_s in
    let diff = A.Set.union diff1 diff2 in

    let errors = A.Set.fold (fun a errors ->
        let source, attr, file =
          if A.Map.mem a attrs_repo then
            ("repository", a, A.Map.find a attrs_repo)
          else
            ("opam", a, A.Map.find a attrs_opam) in
        { source; attr; file } :: errors
      ) diff [] in

    if errors <> [] then
      sync_errors errors

  let packages repo root =
    packages repo root;
    archives repo root

end
