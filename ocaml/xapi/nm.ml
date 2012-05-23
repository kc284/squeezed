(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module D=Debug.Debugger(struct let name="xapi" end)
open D

open Stringext
open Listext
open Threadext
open Fun
open Db_filter_types

module Net = (val (Network.get_client ()) : Network.CLIENT)
open Network_interface

(* Protect a bunch of local operations with a mutex *)
let local_m = Mutex.create ()
let with_local_lock f = Mutex.execute local_m f

let is_dom0_interface pif_r = pif_r.API.pIF_ip_configuration_mode <> `None

let determine_mtu pif_rc net_rc =
	let mtu = Int64.to_int net_rc.API.network_MTU in
	if List.mem_assoc "mtu" pif_rc.API.pIF_other_config then
		let value = List.assoc "mtu" pif_rc.API.pIF_other_config in
		try
			int_of_string value
		with _ ->
			debug "Invalid value for mtu = %s" value;
			mtu
	else
		mtu

let determine_ethtool_settings oc =
	let proc key =
		if List.mem_assoc ("ethtool-" ^ key) oc then
			let value = List.assoc ("ethtool-" ^ key) oc in
			if value = "true" || value = "on" then
				[key, "on"]
			else if value = "false" || value = "off" then
				[key, "off"]
			else begin
				debug "Invalid value for ethtool-%s = %s. Must be on|true|off|false." key value;
				[]
			end
		else
			[]
	in
	let speed =
		if List.mem_assoc "ethtool-speed" oc then
			let value = List.assoc "ethtool-speed" oc in
			if value = "10" || value = "100" || value = "1000" then
				["speed", value]
			else begin
				debug "Invalid value for ethtool-speed = %s. Must be 10|100|1000." value;
				[]
			end
		else
			[]
	in
	let duplex =
		if List.mem_assoc "ethtool-duplex" oc then
			let value = List.assoc "ethtool-duplex" oc in
			if value = "half" || value = "full" then
				["duplex", value]
			else begin
				debug "Invalid value for ethtool-duplex = %s. Must be half|full." value;
				[]
			end
		else
			[]
	in
	let autoneg = proc "autoneg" in
	let settings = speed @ duplex @ autoneg in
	let offload = List.flatten (List.map proc ["rx"; "tx"; "sg"; "tso"; "ufo"; "gso"; "gro"; "lro"]) in
	settings, offload

let determine_other_config ~__context pif_rc net_rc =
	let pif_oc = pif_rc.API.pIF_other_config in
	let net_oc = net_rc.API.network_other_config in
	let pool_oc = Db.Pool.get_other_config ~__context ~self:(Helpers.get_pool ~__context) in
	let additional = ["network-uuids", net_rc.API.network_uuid] in
	(pool_oc |> (List.update_assoc net_oc) |> (List.update_assoc pif_oc)) @ additional

let create_bond ~__context bond mtu =
	(* Get all information we need from the DB before doing anything that may drop our
	 * management connection *)
	let master = Db.Bond.get_master ~__context ~self:bond in
	let master_rc = Db.PIF.get_record ~__context ~self:master in
	let slaves = Db.Bond.get_slaves ~__context ~self:bond in
	let slave_devices_and_bridges = List.map (fun pif ->
		let device = Db.PIF.get_device ~__context ~self:pif in
		let bridge =
			let network = Db.PIF.get_network ~__context ~self:pif in
			Db.Network.get_bridge ~__context ~self:network
		in
		device, bridge
	) slaves in
	let master_net_rc = Db.Network.get_record ~__context ~self:master_rc.API.pIF_network in
	let props = Db.Bond.get_properties ~__context ~self:bond in
	let mode = Db.Bond.get_mode ~__context ~self:bond in
	let other_config = determine_other_config ~__context master_rc master_net_rc in
	let persistent_b = is_dom0_interface master_rc in

	(* clean up bond slaves *)
	let cleanup = List.map (fun (_, bridge) -> bridge, true) slave_devices_and_bridges in
	let interface_config =
		List.map (fun (device, bridge) ->
			device, {default_interface with mtu}
		) slave_devices_and_bridges
	in

	let port = master_rc.API.pIF_device in
	let mac = master_rc.API.pIF_MAC in

	(* set bond properties *)
	let props =
		if List.length slaves > 1 then
			let hashing_algorithm =
				if List.mem_assoc "hashing_algorithm" props then
					List.assoc "hashing_algorithm" props
				else
					""
			in
			let props = [
				"mode", Record_util.bond_mode_to_string mode;
				"miimon", "100";
				"downdelay", "200";
				"updelay", "31000";
				"use_carrier", "1";
				"hashing-algorithm", hashing_algorithm
			] in
			let overrides = List.filter_map (fun (k, v) ->
				if String.startswith "bond-" k then
					Some ((String.sub_to_end k 5), v)
				else
					None
			) master_rc.API.pIF_other_config in
			(* add defaults for properties that are not overridden *)
			(List.filter (fun (k, _) -> not (List.mem_assoc k overrides)) props) @ overrides
		else
			(* Sometimes a "Bond" is not actually a bond... *)
			[]
	in

	let ports = [port, {interfaces=(List.map (fun (device, _) -> device) slave_devices_and_bridges);
		bond_properties=props; mac}] in
	cleanup,
	[master_net_rc.API.network_bridge, {default_bridge with ports; bridge_mac=(Some mac); other_config;
		persistent_b}],
	interface_config

let destroy_bond ~__context ~force bond =
	let master = Db.Bond.get_master ~__context ~self:bond in
	let network = Db.PIF.get_network ~__context ~self:master in
	[Db.Network.get_bridge ~__context ~self:network, force]

let create_vlan ~__context vlan =
	let master = Db.VLAN.get_untagged_PIF ~__context ~self:vlan in
	let master_rc = Db.PIF.get_record ~__context ~self:master in
	let master_network_rc = Db.Network.get_record ~__context ~self:master_rc.API.pIF_network in

	let slave = Db.VLAN.get_tagged_PIF ~__context ~self:vlan in
	let slave_rc = Db.PIF.get_record ~__context ~self:slave in
	let slave_network_rc = Db.Network.get_record ~__context ~self:slave_rc.API.pIF_network in

	let tag = Int64.to_int (Db.VLAN.get_tag ~__context ~self:vlan) in
	let other_config = determine_other_config ~__context master_rc master_network_rc in
	let other_config = List.replace_assoc "network-uuids"
		(master_network_rc.API.network_uuid ^ ";" ^ slave_network_rc.API.network_uuid) other_config in
	let persistent_b = is_dom0_interface master_rc in

	[master_network_rc.API.network_bridge,
		{default_bridge with vlan=(Some (slave_network_rc.API.network_bridge, tag)); other_config;
		persistent_b}]

let destroy_vlan ~__context vlan =
	let master = Db.VLAN.get_untagged_PIF ~__context ~self:vlan in
	let bridge =
		let network = Db.PIF.get_network ~__context ~self:master in
		Db.Network.get_bridge ~__context ~self:network
	in
	[bridge, false]

let get_bond pif_rc =
	match pif_rc.API.pIF_bond_master_of with
	| [] -> None
	| bond :: _ ->
		Some bond

let get_vlan pif_rc =
	if pif_rc.API.pIF_VLAN_master_of = Ref.null then
		None
	else
		Some pif_rc.API.pIF_VLAN_master_of

let get_tunnel pif_rc =
	if pif_rc.API.pIF_tunnel_access_PIF_of = [] then
		None
	else
		Some (List.hd pif_rc.API.pIF_tunnel_access_PIF_of)

let get_pif_type pif_rc =
	match get_vlan pif_rc with
	| Some vlan -> `vlan_pif vlan
	| None ->
		match get_bond pif_rc with
		| Some bond -> `bond_pif bond
		| None ->
			match get_tunnel pif_rc with
			| Some tunnel -> `tunnel_pif tunnel
			| None -> `phy_pif

let rec create_bridges ~__context pif_rc net_rc =
	let mtu = determine_mtu pif_rc net_rc in
	let other_config = determine_other_config ~__context pif_rc net_rc in
	let persistent_b = is_dom0_interface pif_rc in
	match get_pif_type pif_rc with
	| `tunnel_pif _ ->
		[],
		[net_rc.API.network_bridge, {default_bridge with bridge_mac=(Some pif_rc.API.pIF_MAC); persistent_b}],
		[]
	| `vlan_pif vlan ->
		let slave = Db.VLAN.get_tagged_PIF ~__context ~self:vlan in
		let pif_rc = Db.PIF.get_record ~__context ~self:slave in
		let net_rc = Db.Network.get_record ~__context ~self:pif_rc.API.pIF_network in
		let cleanup, bridge_config, interface_config = create_bridges ~__context pif_rc net_rc in
		cleanup,
		create_vlan ~__context vlan @ bridge_config,
		interface_config
	| `bond_pif bond ->
		let cleanup, bridge_config, interface_config = create_bond ~__context bond mtu in
		let interface_config = (pif_rc.API.pIF_device, {default_interface with mtu}) :: interface_config in
		cleanup, bridge_config, interface_config
	| `phy_pif  ->
		let cleanup =
			if pif_rc.API.pIF_bond_slave_of <> Ref.null then
				destroy_bond ~__context ~force:true pif_rc.API.pIF_bond_slave_of
			else
				[]
		in
		let (ethtool_settings, ethtool_offload) =
			determine_ethtool_settings pif_rc.API.pIF_other_config in
		let ports = [pif_rc.API.pIF_device, {default_port with interfaces=[pif_rc.API.pIF_device]}] in
		cleanup,
		[net_rc.API.network_bridge, {default_bridge with ports; bridge_mac=(Some pif_rc.API.pIF_MAC);
			other_config; persistent_b}],
		[pif_rc.API.pIF_device, {default_interface with mtu; ethtool_settings; ethtool_offload}]

let rec destroy_bridges ~__context ~force pif_rc bridge =
	match get_pif_type pif_rc with
	| `tunnel_pif _ ->
		[bridge, false]
	| `vlan_pif vlan ->
		let cleanup = destroy_vlan ~__context vlan in
		let slave = Db.VLAN.get_tagged_PIF ~__context ~self:vlan in
		let rc = Db.PIF.get_record ~__context ~self:slave in
		if not rc.API.pIF_currently_attached then
			let bridge = Db.Network.get_bridge ~__context ~self:rc.API.pIF_network in
			(destroy_bridges ~__context ~force rc bridge) @ cleanup
		else
			cleanup
	| `bond_pif bond ->
		destroy_bond ~__context ~force bond
	| `phy_pif  ->
		[bridge, false]

(* Determine the gateway and DNS PIFs:
 * If one of the PIFs with IP has other_config:defaultroute=true, then
 * pick this one as gateway PIF. If there are multiple, pick a random one of these.
 * If there are none, then pick the management interface. If there is no management
 * interface, pick a random PIF.
 * Similarly for the DNS PIF, but with other_config:peerdns. *)
let is_gateway_and_dns_pifs ~__context pif management_interface =
	let localhost = Helpers.get_localhost ~__context in
	let ip_pifs = Db.PIF.get_records_where ~__context
		~expr:(And (Eq (Field "host", Literal (Ref.string_of localhost)),
			Not (Eq (Field "ip_configuration_mode", Literal "None")))) in
	let gateway_pif =
		let oc = List.filter (fun (_, r) ->
			List.mem_assoc "defaultroute" r.API.pIF_other_config &&
			List.assoc "defaultroute" r.API.pIF_other_config = "true"
		) ip_pifs in
		match oc with
		| (p, r) :: _ ->
			warn "multiple PIFs with other_config:defaultroute=true - choosing %s" r.API.pIF_device;
			p
		| [] ->
			if management_interface then
				pif
			else
				let mgmt = List.filter (fun (_, r) -> r.API.pIF_management) ip_pifs in
				match mgmt with
				| (p, _) :: _ -> p
				| [] ->
					let (p, r) = List.hd ip_pifs in
					warn "no gateway PIF found - choosing %s" r.API.pIF_device;
					p
	in
	let dns_pif =
		let oc = List.filter (fun (_, r) ->
			List.mem_assoc "peerdns" r.API.pIF_other_config &&
			List.assoc "peerdns" r.API.pIF_other_config = "true"
		) ip_pifs in
		match oc with
		| (p, r) :: _ ->
			warn "multiple PIFs with other_config:peerdns=true - choosing %s" r.API.pIF_device;
			p
		| [] ->
			if management_interface then
				pif
			else
				let mgmt = List.filter (fun (_, r) -> r.API.pIF_management) ip_pifs in
				match mgmt with
				| (p, _) :: _ -> p
				| [] ->
					let (p, r) = List.hd ip_pifs in
					warn "no DNS PIF found - choosing %s" r.API.pIF_device;
					p
	in
	gateway_pif = pif, dns_pif = pif

let determine_static_routes net_rc =
	if List.mem_assoc "static-routes" net_rc.API.network_other_config then
		try
			let routes = String.split ',' (List.assoc "static-routes" net_rc.API.network_other_config) in
			List.map (fun route -> Scanf.sscanf route "%[^/]/%d/%[^/]" (fun a b c -> Unix.inet_addr_of_string a, b, Unix.inet_addr_of_string c)) routes
		with _ -> []
	else
		[]

let bring_pif_up ~__context ?(management_interface=false) (pif: API.ref_PIF) =
	with_local_lock (fun () ->
		let dbg = Context.string_of_task __context in
		let rc = Db.PIF.get_record ~__context ~self:pif in
		let net_rc = Db.Network.get_record ~__context ~self:rc.API.pIF_network in
		let bridge = net_rc.API.network_bridge in

		(* Call networkd even if currently_attached is false, just to update its state *)
		debug "Making sure that PIF %s is up" rc.API.pIF_uuid;

		let old_ip = try Net.Interface.get_ipv4_addr dbg ~name:bridge with _ -> [] in

		(* If the PIF is a bond master, the bond slaves will now go down *)
		(* Interface-reconfigure in bridge mode requires us to set currently_attached to false here *)
		begin match rc.API.pIF_bond_master_of with
			| [] -> ()
			| bond :: _ ->
				let slaves = Db.Bond.get_slaves ~__context ~self:bond in
				List.iter (fun self -> Db.PIF.set_currently_attached ~__context ~self ~value:false) slaves
		end;

		Network.transform_networkd_exn pif (fun () ->
			let persistent = is_dom0_interface rc in
		(*	let dhcp_options =
				if rc.API.pIF_ip_configuration_mode = `DHCP then
					determine_dhcp_options ~__context pif management_interface
				else []
			in*)
			let is_gateway_pif, is_dns_pif = is_gateway_and_dns_pifs ~__context pif management_interface in

			(* Setup network infrastructure *)
			let cleanup, bridge_config, interface_config = create_bridges ~__context rc net_rc in
			List.iter (fun (name, force) -> Net.Bridge.destroy dbg ~name ~force ()) cleanup;
			Net.Bridge.make_config dbg ~config:bridge_config ();
			Net.Interface.make_config dbg ~config:interface_config ();

			(* Configure IPv4 parameters and DNS *)
			let ipv4_conf, ipv4_gateway, dns =
				match rc.API.pIF_ip_configuration_mode with
				| `None -> None4, None, ([], [])
				| `DHCP -> DHCP4, None, ([], [])
				| `Static ->
					let conf = (Static4 [
						Unix.inet_addr_of_string rc.API.pIF_IP,
						netmask_to_prefixlen rc.API.pIF_netmask]) in
					let gateway =
						if rc.API.pIF_gateway <> "" then
							Some (Unix.inet_addr_of_string rc.API.pIF_gateway)
						else
							None in
					let dns =
						if rc.API.pIF_DNS <> "" then begin
							let nameservers = List.map Unix.inet_addr_of_string (String.split ',' rc.API.pIF_DNS) in
							let domains =
								if List.mem_assoc "domain" rc.API.pIF_other_config then
									let domains = List.assoc "domain" rc.API.pIF_other_config in
									try
										String.split ',' domains
									with _ ->
										warn "Invalid DNS search domains: %s" domains;
										[]
								else
									[]
							in
							nameservers, domains
						end else
							[], []
					in
					conf, gateway, dns
			in
			let ipv4_routes = determine_static_routes net_rc in

			(* Configure IPv6 parameters *)
			let ipv6_conf, ipv6_gateway =
				match rc.API.pIF_ipv6_configuration_mode with
				| `None -> None6, None
				| `DHCP -> DHCP6, None
				| `Autoconf -> Autoconf6, None
				| `Static ->
					let addresses = List.filter_map (fun addr_and_prefixlen ->
						try
							let n = String.index addr_and_prefixlen '/' in
							let addr = Unix.inet_addr_of_string (String.sub addr_and_prefixlen 0 n) in
							let prefixlen = int_of_string (String.sub_to_end addr_and_prefixlen (n + 1)) in
							Some (addr, prefixlen)
						with _ -> None
					) rc.API.pIF_IPv6 in
					let conf = Static6 addresses in
					let gateway =
						if rc.API.pIF_ipv6_gateway <> "" then
							Some (Unix.inet_addr_of_string rc.API.pIF_ipv6_gateway)
						else
							None in
					conf, gateway
			in

			if is_gateway_pif then
				Net.set_gateway_interface dbg ~name:bridge;
			if is_dns_pif then
				Net.set_dns_interface dbg ~name:bridge;
			let mtu = determine_mtu rc net_rc in
			let (ethtool_settings, ethtool_offload) = determine_ethtool_settings net_rc.API.network_other_config in
			let interface_config = [bridge, {ipv4_conf; ipv4_gateway; ipv6_conf; ipv6_gateway;
				ipv4_routes; dns; ethtool_settings; ethtool_offload; mtu; persistent_i=persistent}] in
			Net.Interface.make_config dbg ~config:interface_config ()
		);

		let new_ip = try Net.Interface.get_ipv4_addr dbg ~name:bridge with _ -> [] in
		if new_ip <> old_ip then begin
			warn "An IP address of dom0 was changed";
			warn "About to kill idle client stunnels";
			(* The master_connection would otherwise try to take a broken stunnel from the cache *)
			Stunnel_cache.flush ();
			warn "About to forcibly reset the master connection";
			Master_connection.force_connection_reset ()
		end;

		if rc.API.pIF_currently_attached = false || management_interface then begin
			if management_interface then begin
				warn "About to kill active client stunnels";
				let stunnels =
					let all = Locking_helpers.Thread_state.get_all_acquired_resources () in
					debug "There are %d allocated resources" (List.length all);
					List.filter (function Locking_helpers.Process("stunnel", _) -> true | _ -> false) all in
				debug "Of which %d are stunnels" (List.length stunnels);
				List.iter Locking_helpers.kill_resource stunnels;
			end;

			Db.PIF.set_currently_attached ~__context ~self:pif ~value:true;

			(* If the PIF is a bond slave, the bond master will now be down *)
			begin match rc.API.pIF_bond_slave_of with
				| bond when bond = Ref.null -> ()
				| bond ->
					let master = Db.Bond.get_master ~__context ~self:bond in
					Db.PIF.set_currently_attached ~__context ~self:master ~value:false
			end;

			(* sync MTU *)
			(try
				let mtu = Int64.of_string (Netdev.get_mtu bridge) in
				Db.PIF.set_MTU ~__context ~self:pif ~value:mtu
			with _ ->
				debug "could not update MTU field on PIF %s" rc.API.pIF_uuid
			);

			Xapi_mgmt_iface.on_dom0_networking_change ~__context
		end
	)

let bring_pif_down ~__context ?(force=false) (pif: API.ref_PIF) =
	with_local_lock (fun () ->
		Network.transform_networkd_exn pif (fun () ->
			let dbg = Context.string_of_task __context in
			let rc = Db.PIF.get_record ~__context ~self:pif in
			debug "Making sure that PIF %s down" rc.API.pIF_uuid;

			let bridge = Db.Network.get_bridge ~__context ~self:rc.API.pIF_network in
			let cleanup = destroy_bridges ~__context ~force rc bridge in
			List.iter (fun (name, force) -> Net.Bridge.destroy dbg ~name ~force ()) cleanup;
			Net.Interface.set_persistent dbg ~name:bridge ~value:false;

			Db.PIF.set_currently_attached ~__context ~self:pif ~value:false
		)
	)

