(*
 * $Id$
 *
 * Multi aircrafts map display
 *  
 * Copyright (C) 2004 CENA/ENAC, Pascal Brisset, Antoine Drouin
 *
 * This file is part of paparazzi.
 *
 * paparazzi is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * paparazzi is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with paparazzi; see the file COPYING.  If not, write to
 * the Free Software Foundation, 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA. 
 *
 *)

open Printf
open Latlong

module Ground_Pprz = Pprz.Protocol(struct let name = "ground" end)

type color = string

let fos = float_of_string
let list_separator = Str.regexp ","

(** parameters used for creating the vertical display window *) 
let max_graduations = 20

let vertical_delta = 5.0

let max_east = 2000.0

let max_label = 4 

let approx_ground_altitude = ref 0.0

module G = MapCanvas

let home = Env.paparazzi_home
let (//) = Filename.concat
let default_path_srtm = home // "data" // "srtm"
let default_path_maps = home // "data" // "maps" // ""
let default_path_missions = home // "conf"


type aircraft = {
    track : MapTrack.track;
    color: color;
    mutable fp_group : MapWaypoints.group option
  }

let live_aircrafts = Hashtbl.create 3

let map_ref = ref None

let float_attr = fun xml a -> float_of_string (ExtXml.attrib xml a)

let load_map = fun (geomap:G.widget) (vertical_display:MapCanvas.basic_widget) xml_map ->
  let dir = Filename.dirname xml_map in
  let xml_map = Xml.parse_file xml_map in
  let image = dir // ExtXml.attrib xml_map "file"
  and scale = float_attr xml_map "scale"
  and utm_zone =
    try int_of_string (Xml.attrib xml_map "utm_zone") with
      _ -> 31 in
  geomap#set_world_unit scale;
  approx_ground_altitude := ( try (float_attr xml_map "approx_ground_altitude") 
      with _ -> 0.0);
  vertical_display#set_world_unit scale;
  let one_ref = ExtXml.child xml_map "point" in
  let x = float_attr one_ref "x" and y = float_attr one_ref "y"
  and utm_x = float_attr one_ref "utm_x" and utm_y = float_attr one_ref "utm_y" in
  let utm_x0 = utm_x -. x *. scale
  and utm_y0 = utm_y +. y *. scale in

  let utm_ref =
    match !map_ref with
      None ->
	let utm0 = {utm_x = utm_x0;  utm_y = utm_y0; utm_zone = utm_zone } in
	map_ref := Some utm0;
	utm0
    | Some utm ->
	assert (utm_zone = utm.utm_zone);
	utm in

  let wgs84_of_en = fun en ->
    of_utm WGS84 {utm_x = utm_ref.utm_x +. en.G.east; utm_y = utm_ref.utm_y +. en.G.north; utm_zone = utm_zone} in

  geomap#set_wgs84_of_en wgs84_of_en;
  let en0 = {G.east=utm_x0 -. utm_ref.utm_x; north=utm_y0 -. utm_ref.utm_y} in
  ignore (geomap#display_map en0 (GdkPixbuf.from_file image));
  geomap#moveto en0


let file_of_url = fun url ->
  if String.sub url 0 7 = "file://" then
    String.sub url 7 (String.length url - 7)
  else
    let tmp_file = Filename.temp_file "fp" ".xml" in
    let c = sprintf "wget --cache=off -O %s %s" tmp_file url in
    if Sys.command c = 0 then
      tmp_file
    else
      failwith c

let load_mission = fun color geomap url ->
  let file = file_of_url url in
  let xml = Xml.parse_file file in
  let xml = ExtXml.child xml "flight_plan" in
  let lat0 = float_attr xml "lat0"
  and lon0 = float_attr xml "lon0" in
  let utm0 = utm_of WGS84 {posn_lat = (Deg>>Rad)lat0; posn_long = (Deg>>Rad)lon0 } in
  let waypoints = ExtXml.child xml "waypoints" in
  let max_dist_from_home = float_attr xml "MAX_DIST_FROM_HOME" in
  
  let utm_ref =
    match !map_ref with
      None ->
	map_ref := Some utm0;
	utm0
    | Some utm ->
	assert (utm0.utm_zone = utm.utm_zone);
	utm in
  let en_of_xy = fun x y ->
    {G.east = x +. utm0.utm_x -. utm_ref.utm_x;
     G.north = y +. utm0.utm_y -. utm_ref.utm_y } in

  let fp = new MapWaypoints.group ~color ~editable:false geomap in
  List.iter
    (fun wp ->
      let en = en_of_xy (float_attr wp "x") (float_attr wp "y") in
      let alt = try Some (float_attr wp "alt") with _ -> None in
      ignore (MapWaypoints.waypoint fp ~name:(ExtXml.attrib wp "name") ?alt en);
      if  ExtXml.attrib wp "name" = "HOME" then
	ignore (geomap#circle ~color en max_dist_from_home)
    ) 
    (Xml.children waypoints);
  fp


let aircraft_pos_msg = fun track utm_x_ utm_y_ heading altitude speed climb ->
  match !map_ref with
    None -> ()
  | Some utm0 ->
      let en =  {G.east = utm_x_ -. utm0.utm_x; north = utm_y_ -. utm0.utm_y } in
      let h = 
	try
	  Srtm.of_utm { utm_zone = utm0.utm_zone; utm_x = utm_x_; utm_y = utm_y_}
	with
	  _ -> truncate altitude
      in
      track#move_icon en heading altitude (float_of_int h) speed climb

let carrot_pos_msg = fun track utm_x utm_y ->
  match !map_ref with
    None -> ()
  | Some utm0 ->
      let en =  {G.east = utm_x -. utm0.utm_x; north = utm_y -. utm0.utm_y } in
      track#move_carrot en

let cam_pos_msg = fun track utm_x utm_y target_utm_x target_utm_y ->
  match !map_ref with
    None -> ()
  | Some utm0 ->
      let en =  {G.east = utm_x -. utm0.utm_x; north = utm_y -. utm0.utm_y } in
      let target_en =  {G.east = target_utm_x -. utm0.utm_x; north = target_utm_y -. utm0.utm_y } in  
      track#move_cam en target_en

let circle_status_msg = fun track utm_x utm_y radius ->
  match !map_ref with
    None -> ()
  | Some utm0 ->
      let en =  {G.east = utm_x -. utm0.utm_x; north = utm_y -. utm0.utm_y } in  
      track#draw_circle en radius

let segment_status_msg = fun track utm_x utm_y utm2_x utm2_y ->
  match !map_ref with
    None -> ()
  | Some utm0 ->
      let en =  {G.east = utm_x -. utm0.utm_x; north = utm_y -. utm0.utm_y } in  
      let en2 =  {G.east = utm2_x -. utm0.utm_x; north = utm2_y -. utm0.utm_y } in
      track#draw_segment en en2

let circle_status_msg = fun track utm_x utm_y radius ->
  match !map_ref with
    None -> ()
  | Some utm0 ->
      let en =  {G.east = utm_x -. utm0.utm_x; north = utm_y -. utm0.utm_y } in  
      track#draw_circle en radius

let ap_status_msg = fun track flight_time ->
    track#update_ap_status flight_time
    

let new_color =
  let colors = ref ["red"; "blue"; "green"] in
  fun () ->
    match !colors with
      x::xs ->
	colors := xs @ [x];
	x
    | [] -> failwith "new_color"


let ask_fp = fun geomap ac ->
  let get_config = fun _sender values ->
    let file = Pprz.string_assoc "flight_plan" values in
    let ac = Hashtbl.find live_aircrafts ac in
    try
      ac.fp_group <- Some (load_mission ac.color  geomap file)
    with Failure x ->
      GToolbox.message_box ~title:"Error while loading flight plan" x in
  Ground_Pprz.message_req "map2d" "CONFIG" ["ac_id", Pprz.String ac] get_config


let show_mission = fun geomap ac on_off ->
  if on_off then
    ask_fp geomap ac
  else
    let a = Hashtbl.find live_aircrafts ac in
    match a.fp_group with
      None -> ()
    | Some g -> 
	a.fp_group <- None;
	g#group#destroy ()

let resize_track = fun ac track ->
  match GToolbox.input_string ~text:(string_of_int track#size) ~title:ac "Track size" with
    None -> ()
  | Some s -> track#resize (int_of_string s)
	 

let one_new_ac = fun (geomap:MapCanvas.widget)(vertical_display:MapCanvas.basic_widget) ac ->
  if not (Hashtbl.mem live_aircrafts ac) then begin
    let ac_menu = geomap#factory#add_submenu ac in
    let ac_menu_fact = new GMenu.factory ac_menu in
    let fp = ac_menu_fact#add_check_item "Fligh Plan" ~active:false in
    ignore (fp#connect#toggled (fun () -> show_mission geomap ac fp#active));
    let color = new_color () in
    let track = new MapTrack.track ~name:ac ~color:color geomap vertical_display in
    ignore (ac_menu_fact#add_item "Clear Track" ~callback:(fun () -> track#clear_map2D));
    ignore (ac_menu_fact#add_item "Resize Track" ~callback:(fun () -> resize_track ac track));
    let cam = ac_menu_fact#add_check_item "Cam Display" ~active:false in
    ignore (cam#connect#toggled (fun () -> track#set_cam_state cam#active));
    let ac_menu_vertical = vertical_display#factory#add_submenu ac in
    let ac_menu_fact_vertical = new GMenu.factory ac_menu_vertical in
    let params = ac_menu_fact#add_check_item "flight param. display" ~active:false in
    ignore (params#connect#toggled (fun () -> track#set_params_state params#active));
    let v_params = ac_menu_fact_vertical#add_check_item "flight param. display" ~active:false in
    ignore (v_params#connect#toggled (fun () -> track#set_v_params_state v_params#active));
     let event_ac = fun e ->
      match e with
	`BUTTON_PRESS _ | `BUTTON_RELEASE _ -> 
	  Ground_Pprz.message_send "ground" "SELECTED" ["aircraft_id", Pprz.String ac];
	  true
      | _ -> false in
    ignore (track#aircraft#connect#event event_ac);
    Hashtbl.add live_aircrafts ac { track = track; color = color; fp_group = None }
  end
      
      
let live_aircrafts_msg = fun (geomap:MapCanvas.widget)(vertical_display:MapCanvas.basic_widget) acs ->
  let acs = Pprz.string_assoc "ac_list" acs in
  let acs = Str.split list_separator acs in
  List.iter (one_new_ac geomap vertical_display) acs


let listen_flight_params = fun () ->
  let get_fp = fun _sender vs ->
    let ac_id = Pprz.string_assoc "ac_id" vs in
    try
      let ac = Hashtbl.find live_aircrafts ac_id in
      let a = fun s -> Pprz.float_assoc s vs in
      aircraft_pos_msg ac.track (a "east") (a "north") (a "course") (a "alt")  (a "speed") (a "climb")
    with Not_found -> ()
  in
  ignore (Ground_Pprz.message_bind "FLIGHT_PARAM" get_fp);

  let get_ns = fun _sender vs ->
    let ac_id = Pprz.string_assoc "ac_id" vs in
    try
      let ac = Hashtbl.find live_aircrafts ac_id in
      let a = fun s -> Pprz.float_assoc s vs in
	carrot_pos_msg ac.track (a "target_east") (a "target_north") 
    with Not_found -> ()
  in
  ignore (Ground_Pprz.message_bind "NAV_STATUS" get_ns);

  let get_cam_status = fun _sender vs ->
    let ac_id = Pprz.string_assoc "ac_id" vs in
    try
      let ac = Hashtbl.find live_aircrafts ac_id in
      let a = fun s -> Pprz.float_assoc s vs in
      cam_pos_msg ac.track (a "cam_east") (a "cam_north") (a "target_east") (a "target_north")
    with Not_found -> ()
  in ignore (Ground_Pprz.message_bind "CAM_STATUS" get_cam_status);

  let get_circle_status = fun _sender vs ->
    let ac_id = Pprz.string_assoc "ac_id" vs in
    try
      let ac = Hashtbl.find live_aircrafts ac_id in
      let a = fun s -> Pprz.float_assoc s vs in
      circle_status_msg ac.track (a "circle_east") (a "circle_north") (float_of_string (Pprz.string_assoc "radius" vs)) 
    with Not_found -> ()
  in
  ignore (Ground_Pprz.message_bind "CIRCLE_STATUS" get_circle_status);

  let get_segment_status = fun _sender vs ->
    let ac_id = Pprz.string_assoc "ac_id" vs in
    try
      let ac = Hashtbl.find live_aircrafts ac_id in
      let a = fun s -> Pprz.float_assoc s vs in
      segment_status_msg ac.track (a "segment1_east") (a "segment1_north") (a "segment2_east") (a "segment2_north") 
    with Not_found -> ()
  in
  ignore (Ground_Pprz.message_bind "SEGMENT_STATUS" get_segment_status);

 let get_ap_status = fun _sender vs ->
    let ac_id = Pprz.string_assoc "ac_id" vs in
    try
      let ac = Hashtbl.find live_aircrafts ac_id in
      let a = fun s -> Pprz.string_assoc s vs in
	 ap_status_msg ac.track ( float_of_int (Pprz.int32_assoc "flight_time" vs ))
    with 
      Not_found -> ()
  in
  ignore (Ground_Pprz.message_bind "AP_STATUS" get_ap_status)


let _ =
  let ivy_bus = ref "127.255.255.255:2010"
  and map_file = ref ""
  and mission_file = ref "" in
  let options =
    [ "-b", Arg.String (fun x -> ivy_bus := x), "Bus\tDefault is 127.255.255.25:2010";
      "-m", Arg.String (fun x -> map_file := x), "Map description file"] in
  Arg.parse (options)
    (fun x -> Printf.fprintf stderr "Warning: Don't do anythig with %s\n" x)
    "Usage: ";
  (*                                 *)
  Ivy.init "Paparazzi map 2D" "READY" (fun _ _ -> ());
  Ivy.start !ivy_bus;

  Srtm.add_path default_path_srtm;

  let window = GWindow.window ~title: "Map2d" ~border_width:1 ~width:400 () in
  let vbox= GPack.vbox ~packing: window#add () in
  let vertical_situation = GWindow.window ~title: "Vertical" ~border_width:1 ~width:400 () in
  let vertical_vbox= GPack.vbox ~packing: vertical_situation#add () in
  let quit = fun () -> GMain.Main.quit (); exit 0 in
  ignore (window#connect#destroy ~callback:quit);
  ignore (vertical_situation#connect#destroy ~callback:quit);

  let geomap = new MapCanvas.widget ~height:400 () in
  let accel_group = geomap#menu_fact#accel_group in

  (** widget displaying aircraft vertical position  *)
  let vertical_display = new MapCanvas.basic_widget ~height:400 () in
  let ac_vertical_fact = new GMenu.factory vertical_display#file_menu in
  let time_axis = ac_vertical_fact#add_check_item "x_axis : Time" ~active:false in
    ignore (time_axis#connect#toggled (fun () ->
      let set_one_track = (fun a b -> 
	(b.track)#set_vertical_time_axis time_axis#active) in 
      Hashtbl.iter (set_one_track) live_aircrafts));
  let vertical_graduations = GnoCanvas.group vertical_display#canvas#root in
  vertical_display#set_vertical_factor 10.0;
 
 
  ignore (geomap#menu_fact#add_item "Quit" ~key:GdkKeysyms._Q ~callback:quit);
 

  vbox#pack ~expand:true geomap#frame#coerce;
  vertical_vbox#pack ~expand:true vertical_display#frame#coerce;

  (* Loading an initial map *)
  if !map_file <> "" then begin
    let xml_map_file = Filename.concat default_path_maps !map_file in
    load_map geomap vertical_display xml_map_file
  end;

  let max_level = (float_of_int max_graduations) *. vertical_delta +. !approx_ground_altitude in 
   vertical_display#set_vertical_max_level max_level;
  for i = 0 to max_graduations do
    let level = (float_of_int i) *. vertical_delta in    
    ignore ( vertical_display#segment ~group:vertical_graduations ~fill_color:"blue" {G.east = 0.0 ; G.north = level *. (-. vertical_display#get_vertical_factor) } {G.east = max_east ; G.north =  level *. (-. vertical_display#get_vertical_factor) } ) ;
    for j = 0 to max_label do
    ignore( vertical_display#text ~group:vertical_graduations ~fill_color:"red" ~x_offset:30.0 ~y_offset:(-.0.5) {G.east = (float_of_int j) *. max_east /. (float_of_int max_label) ; G.north = level *. (-. vertical_display#get_vertical_factor) } ((string_of_float ( max_level -. level) )^" m") )
    done;
  done;   

  ignore (Glib.Timeout.add 5000 (fun () -> Ground_Pprz.message_req "map2d" "AIRCRAFTS" [] (fun _sender vs -> live_aircrafts_msg geomap vertical_display vs); false));

  ignore (Ground_Pprz.message_bind "NEW_AIRCRAFT" (fun _sender vs -> one_new_ac geomap vertical_display (Pprz.string_assoc "ac_id" vs)));

  listen_flight_params ();

  window#add_accel_group accel_group;
  window#show ();
 
  vertical_situation#show ();
  GMain.Main.main ()
