/*
 * Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
 * SPDX-License-Identifier: Apache-2.0
 */
'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require network';
'require fs';

var callGetInterfaces = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { 'interface': [] }
});

var callGenerateKey = rpc.declare({
	object: 'ha-cluster',
	method: 'generate_key'
});

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ha-cluster'),
			callGetInterfaces(),
			network.getDevices(),
			L.resolveDefault(fs.stat('/usr/sbin/lease-sync'), null)
		]);
	},

	render: function(data) {
		var interfaces = data[1] || [];
		var netDevs = data[2] || [];
		var leaseSyncInstalled = data[3] != null;
		var m, s, o;

		// Build set of VIP addresses to exclude from source address selection
		var vipAddresses = {};
		uci.sections('ha-cluster', 'vip').forEach(function(vip) {
			if (vip.address)
				vipAddresses[vip.address] = true;
		});

		// Filter function for valid source addresses
		var isValidSourceAddress = function(addr) {
			// Exclude loopback
			if (addr.startsWith('127.') || addr === '::1')
				return false;
			// Exclude link-local IPv6
			if (addr.startsWith('fe80:'))
				return false;
			// Exclude VIPs
			if (vipAddresses[addr])
				return false;
			return true;
		};

		// Helper to detect address family
		var isIPv6 = function(addr) {
			return addr && addr.indexOf(':') !== -1;
		};

		var ifaceIconUrl = function(ifname) {
			var dev = null;
			for (var i = 0; i < netDevs.length; i++) {
				if (netDevs[i].getName && netDevs[i].getName() === ifname) {
					dev = netDevs[i];
					break;
				}
			}
			var type = dev ? dev.getType() : 'ethernet';
			return L.resource('icons/%s.svg').format(type);
		};

		m = new form.Map('ha-cluster', _('High Availability - General'),
			_('Configure a high availability cluster with 2 or more routers. Advanced options are available in the Advanced pages.'));

		// Global Settings Section
		s = m.section(form.NamedSection, 'config', 'global', _('Cluster Configuration'));
		s.anonymous = false;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable HA Cluster'),
			_('Enable high availability clustering on this router'));
		o.rmempty = false;

		o = s.option(form.Value, 'node_priority', _('Priority'),
			_('VRRP priority (1-255). Higher priority becomes MASTER.'));
		o.datatype = 'range(1,255)';
		o.placeholder = '100';
		o.default = '100';
		o.rmempty = false;

		// Peer Configuration
		s = m.section(form.GridSection, 'peer', _('Peer Routers'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		// Custom handleAdd following DDNS pattern:
		// 1. Show modal with separate form.Map (isolated from main form)
		// 2. On Add: save main form first (preserves pending changes like node_name)
		// 3. Then add new peer to UCI
		// 4. Then refresh main form (now includes saved changes + new peer)
		s.handleAdd = function(ev) {
			var _this = this;
			var mainMap = this.map;

			var m2 = new form.Map('ha-cluster');
			var s2 = m2.section(form.NamedSection, '_new_');

			s2.render = function() {
				return Promise.all([
					{},
					this.renderUCISection('_new_')
				]).then(this.renderContents.bind(this));
			};

			var peerName = s2.option(form.Value, 'name', _('Peer Name'));
			peerName.rmempty = false;
			peerName.datatype = 'hostname';
			peerName.placeholder = 'router2';

			var peerAddress = s2.option(form.Value, 'address', _('Peer IP Address'));
			peerAddress.rmempty = false;
			peerAddress.datatype = 'ipaddr';
			peerAddress.placeholder = '192.168.1.2';

			var peerSource = s2.option(form.ListValue, 'source_address', _('Source Address'),
				_('Local IP to use when contacting this peer. Must match address family (IPv4/IPv6) of peer.'));
			// Populate with all valid source addresses
			interfaces.forEach(function(iface) {
				(iface['ipv4-address'] || []).forEach(function(addr) {
					if (isValidSourceAddress(addr.address))
						peerSource.value(addr.address, addr.address + ' (' + iface.interface + ')');
				});
				(iface['ipv6-address'] || []).forEach(function(addr) {
					if (isValidSourceAddress(addr.address))
						peerSource.value(addr.address, addr.address + ' (' + iface.interface + ')');
				});
			});

			m2.render().then(function(nodes) {
				ui.showModal(_('Add Peer Router'), [
					nodes,
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'btn',
							'click': ui.hideModal
						}, _('Cancel')), ' ',
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function() {
								var nameVal = peerName.formvalue('_new_');
								var addrVal = peerAddress.formvalue('_new_');
								var sourceVal = peerSource.formvalue('_new_');

								if (!nameVal || !addrVal) {
									ui.addNotification(null, E('p', _('Please fill in all fields')), 'warning');
									return;
								}

								if (!sourceVal) {
									ui.addNotification(null, E('p', _('Please select a source address')), 'warning');
									return;
								}

								// Validate address family match
								var peerIsV6 = isIPv6(addrVal);
								var sourceIsV6 = isIPv6(sourceVal);
								if (peerIsV6 !== sourceIsV6) {
									ui.addNotification(null, E('p', _('Address family mismatch: peer and source must both be IPv4 or both be IPv6')), 'warning');
									return;
								}

								// Save main form first (preserves all pending changes)
								// Then add new peer, then refresh
								mainMap.save(function() {
									uci.add('ha-cluster', 'peer');
									var sections = uci.sections('ha-cluster', 'peer');
									var newSection = sections[sections.length - 1]['.name'];
									uci.set('ha-cluster', newSection, 'name', nameVal);
									uci.set('ha-cluster', newSection, 'address', addrVal);
									uci.set('ha-cluster', newSection, 'source_address', sourceVal);
								}).then(function() {
									ui.hideModal();
									return mainMap.load();
								}).then(function() {
									return mainMap.reset();
								}).catch(function(err) {
									ui.hideModal();
									ui.addNotification(null,
										E('p', {}, _('Failed to add peer: ') + err.message),
										'danger');
								});
							}
						}, _('Add'))
					])
				], 'cbi-modal');
			});
		};

		o = s.option(form.DummyValue, '_display', _('Peer'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var name = uci.get('ha-cluster', section_id, 'name') || '-';
			var addr = uci.get('ha-cluster', section_id, 'address') || '';
			return name + (addr ? ' (' + addr + ')' : '');
		};

		o = s.option(form.Value, 'name', _('Peer Name'));
		o.placeholder = 'router2';
		o.datatype = 'hostname';
		o.rmempty = false;
		o.modalonly = true;

		var addrOpt = s.option(form.Value, 'address', _('Peer IP Address'));
		addrOpt.datatype = 'ipaddr';
		addrOpt.placeholder = '192.168.1.2';
		addrOpt.rmempty = false;
		addrOpt.modalonly = true;
		var srcOpt = s.option(form.ListValue, 'source_address', _('Source Address'),
			_('Local IP to use when contacting this peer. Must match address family (IPv4/IPv6) of peer.'));
		// Populate with all valid source addresses
		interfaces.forEach(function(iface) {
			(iface['ipv4-address'] || []).forEach(function(addr) {
				if (isValidSourceAddress(addr.address))
					srcOpt.value(addr.address, addr.address + ' (' + iface.interface + ')');
			});
			(iface['ipv6-address'] || []).forEach(function(addr) {
				if (isValidSourceAddress(addr.address))
					srcOpt.value(addr.address, addr.address + ' (' + iface.interface + ')');
			});
		});
		srcOpt.rmempty = false;
		srcOpt.modalonly = true;

		// Cross-field validation for address family match
		// Using this.map.lookupOption() pattern from VIP validation
		addrOpt.validate = function(section_id, value) {
			var src = this.map.lookupOption('source_address', section_id);
			var srcval = src ? src[0].formvalue(section_id) : '';
			if (value && srcval) {
				var peerIsV6 = value.indexOf(':') !== -1;
				var sourceIsV6 = srcval.indexOf(':') !== -1;
				if (peerIsV6 !== sourceIsV6)
					return _('Family mismatch: both must be IPv4 or both IPv6');
			}
			return true;
		};

		srcOpt.validate = function(section_id, value) {
			var addr = this.map.lookupOption('address', section_id);
			var addrval = addr ? addr[0].formvalue(section_id) : '';
			if (value && addrval) {
				var peerIsV6 = addrval.indexOf(':') !== -1;
				var sourceIsV6 = value.indexOf(':') !== -1;
				if (peerIsV6 !== sourceIsV6)
					return _('Family mismatch: both must be IPv4 or both IPv6');
			}
			return true;
		};


		// Virtual IP Configuration
		s = m.section(form.GridSection, 'vip', _('Virtual IP Addresses'),
			_('Configure VIPs for each interface.'));
		s.anonymous = false;
		s.addremove = true;
		s.sortable = true;
		s.addbtntitle = _('Add VIP...');

		o = s.option(form.DummyValue, '_interface_display', _('Interface'));
		o.textvalue = function(section_id) {
			var ifname = uci.get('ha-cluster', section_id, 'interface') || '';
			return E('span', {}, [
				E('img', { 'src': ifaceIconUrl(ifname), 'style': 'width:24px;height:24px;vertical-align:middle;margin-right:6px' }),
				E('span', {}, ifname || '-')
			]);
		};
		o.modalonly = false;

		o = s.option(form.ListValue, 'interface', _('Interface'));
		o.rmempty = false;
		o.modalonly = true;
		o.editable = true;
		// Populate with available interfaces
		if (interfaces && interfaces.length) {
			var seen = {};
			interfaces.forEach(function(iface) {
				if (iface.interface && iface.interface !== 'loopback') {
					var ifname = iface.interface;
					if (seen[ifname]) return;
					seen[ifname] = true;
					var device = iface.device || ifname;
					o.value(ifname, ifname + (device !== ifname ? ' (' + device + ')' : ''));
				}
			});
		}
		o.cfgvalue = function(section_id) {
			var ifname = uci.get('ha-cluster', section_id, 'interface');
			if (ifname && !(this.keylist || []).includes(ifname)) {
				this.value(ifname, ifname);
			}
			return ifname;
		};

		o = s.option(form.Value, 'address', _('Virtual IP Address (IPv4)'));
		o.datatype = 'ip4addr';
		o.placeholder = '192.168.1.254';
		o.rmempty = true;
		o.description = _('Optional. You can configure IPv4 only, IPv6 only, or both (dual-stack).');
		o.validate = function(section_id, value) {
			var addr6 = this.map.lookupOption('address6', section_id);
			var addr6val = addr6 ? addr6[0].formvalue(section_id) : '';
			if (!value && !addr6val)
				return _('At least one of IPv4 or IPv6 address must be set');
			return true;
		};

		o = s.option(form.Value, 'netmask', _('Netmask'));
		o.datatype = 'ip4addr';
		o.placeholder = '255.255.255.0';
		o.default = '255.255.255.0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends({ address: /.+/ });

		o = s.option(form.Value, 'address6', _('Virtual IP Address (IPv6)'));
		o.datatype = 'ip6addr';
		o.placeholder = 'fd00::1';
		o.rmempty = true;
		o.modalonly = true;
		o.description = _('Optional. If both IPv4 and IPv6 are configured, keepalived will create two separate VRRP instances (IPv4 uses VRID, IPv6 uses VRID+1).');
		o.validate = function(section_id, value) {
			var addr = this.map.lookupOption('address', section_id);
			var addrval = addr ? addr[0].formvalue(section_id) : '';
			if (!value && !addrval)
				return _('At least one of IPv4 or IPv6 address must be set');
			return true;
		};

		o = s.option(form.Value, 'prefix6', _('IPv6 Prefix Length'));
		o.datatype = 'range(1,128)';
		o.placeholder = '64';
		o.default = '64';
		o.rmempty = true;
		o.modalonly = true;
		o.depends({ address6: /.+/ });

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'vrid', _('VRRP Router ID'),
			_('Virtual Router ID (1-255). Must be unique per VIP and same on both routers. If IPv6 is also configured, IPv6 will use VRID+1.'));
		o.datatype = 'range(1,255)';
		o.placeholder = '51';
		o.rmempty = false;
		o.modalonly = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;
			var vrid = parseInt(value);
			if (vrid < 1 || vrid > 255)
				return _('VRID must be between 1 and 255');

			// Check if IPv6 is configured
			var addr6 = this.map.lookupOption('address6', section_id);
			var addr6val = addr6 ? addr6[0].formvalue(section_id) : '';

			if (addr6val && vrid === 255)
				return _('VRID cannot be 255 when IPv6 is configured (IPv6 would use VRID 256, which is out of range)');

			// Check for VRID uniqueness on the same interface
			var iface_opt = this.map.lookupOption('interface', section_id);
			var my_iface = iface_opt ? iface_opt[0].formvalue(section_id) : '';
			var sections = uci.sections('ha-cluster', 'vip');
			for (var i = 0; i < sections.length; i++) {
				if (sections[i]['.name'] === section_id)
					continue;
				var other_iface = uci.get('ha-cluster', sections[i]['.name'], 'interface');
				if (other_iface !== my_iface)
					continue;
				var other_vrid = parseInt(uci.get('ha-cluster', sections[i]['.name'], 'vrid'));
				if (other_vrid === vrid)
					return _('VRID %d is already used by VIP "%s" on the same interface').format(vrid, sections[i]['.name']);
				// Also check IPv6 VRID+1 collisions on same interface
				var other_addr6 = uci.get('ha-cluster', sections[i]['.name'], 'address6');
				if (other_addr6 && other_vrid + 1 === vrid)
					return _('VRID %d collides with IPv6 VRID (VRID+1) of VIP "%s"').format(vrid, sections[i]['.name']);
				if (addr6val && vrid + 1 === other_vrid)
					return _('IPv6 VRID %d (VRID+1) collides with VIP "%s"').format(vrid + 1, sections[i]['.name']);
			}

			return true;
		};


		// Configuration Synchronization (files + method)
		s = m.section(form.NamedSection, 'config', 'global', _('Configuration Synchronization'),
			_('Select which /etc/config files to synchronize and how synchronization is performed.'));

		// Encryption settings first
		o = s.option(form.Flag, 'sync_encryption', _('Encrypt Sync Traffic'),
			_('Enable AES-256-GCM encryption for configuration sync (owsync) and DHCP lease sync (lease-sync). Recommended for security.'));
		o.default = '1';

		var encryption_key_option = s.option(form.Value, 'encryption_key', _('Encryption Key'),
			_('256-bit AES encryption key (64 hexadecimal characters). Used by both owsync and lease-sync. Must be identical on all cluster nodes.'));
		encryption_key_option.depends('sync_encryption', '1');
		encryption_key_option.password = true;
		encryption_key_option.datatype = 'and(hexstring,rangelength(64,64))';
		encryption_key_option.rmempty = true;
		encryption_key_option.placeholder = 'Click "Generate New Key" button below to create a secure random key';

		o = s.option(form.Button, '_generate_key', _('Generate New Key'));
		o.depends('sync_encryption', '1');
		o.inputtitle = _('Generate New Key');
		o.inputstyle = 'action';
		o.onclick = function(section_id) {
			// Show modal
			ui.showModal(_('Generating encryption key...'), [
				E('p', { 'class': 'spinning' }, _('Generating secure random key...'))
			], 'wait');

			// Call RPC method
			L.resolveDefault(callGenerateKey(), {}).then(function(result) {
				ui.hideModal();

				if (result && result.success && result.key) {
					// Set the encryption key field via LuCI option API
					var uiEl = encryption_key_option.getUIElement(section_id);
					if (uiEl) {
						uiEl.setValue(result.key);
					}

					// Show success modal with copy instructions
					ui.showModal(_('Encryption Key Generated'), [
						E('p', {}, _('Encryption key generated successfully!')),
						E('p', { 'class': 'alert-message warning' }, [
							E('strong', {}, _('IMPORTANT:')),
							' ',
							_('Copy this key to all cluster nodes.')
						]),
						E('pre', {
							'style': 'background: #f5f5f5; padding: 10px; border-radius: 4px; user-select: all; font-family: monospace; word-break: break-all;',
							'onclick': 'this.select(); document.execCommand("copy");'
						}, result.key),
						E('p', { 'style': 'margin-top: 1em;' }, _('Click the key above to select and copy it.')),
						E('div', { 'class': 'alert-message info', 'style': 'margin-top: 1em;' }, [
							E('strong', {}, _('Next steps:')),
							E('ol', { 'style': 'margin: 0.5em 0;' }, [
								E('li', {}, _('Save & Apply changes on this router')),
								E('li', {}, _('On each peer router, go to: HA Cluster → Quick Setup → Synchronization Settings')),
								E('li', {}, _('Enable "Encrypt Sync Traffic"')),
								E('li', {}, _('Paste this key into the "Encryption Key" field')),
								E('li', {}, _('Save & Apply on all peer routers'))
							])
						]),
						E('div', { 'class': 'right' }, [
							E('button', {
								'class': 'btn cbi-button-positive',
								'click': ui.hideModal
							}, _('Close'))
						])
					]);

					// Try to copy to clipboard if supported
					if (navigator.clipboard && navigator.clipboard.writeText) {
						navigator.clipboard.writeText(result.key).then(function() {
							ui.addNotification(null, E('p', {}, _('Key copied to clipboard')), 'info');
						}).catch(function(err) {
							console.warn('Clipboard write failed (key still visible in modal):', err);
						});
					}
				} else {
					ui.addNotification(null,
						E('p', {}, _('Failed to generate key: ') + (result.error || _('Unknown error'))),
						'danger');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null,
					E('p', {}, _('Error generating key: ') + err.message),
					'danger');
			});
		};

		// DHCP Lease Sync - maps to service.dhcp.sync_leases
		if (leaseSyncInstalled) {
			o = s.option(form.Flag, '_dhcp_leases', _('Enable Real-time DHCP Lease Sync'),
				_('Synchronize DHCP leases in real-time using the lease-sync daemon for seamless client failover'));
			o.default = '1';
			o.rmempty = false;
			o.cfgvalue = function() { return uci.get('ha-cluster', 'dhcp', 'sync_leases'); };
			o.write = function(section_id, value) { uci.set('ha-cluster', 'dhcp', 'sync_leases', value); };
			o.remove = function() { uci.set('ha-cluster', 'dhcp', 'sync_leases', '0'); };
		} else {
			o = s.option(form.DummyValue, '_dhcp_leases', _('Real-time DHCP Lease Sync'));
			o.rawhtml = true;
			o.cfgvalue = function() {
				return '<em>' + _('Install the <code>lease-sync</code> and <code>dnsmasq-ha</code> packages to enable real-time DHCP lease synchronization.') + '</em>' +
					' <a href="/cgi-bin/luci/admin/system/opkg">' + _('Go to Software page') + ' \u2192</a>';
			};
		}

		// Sync method selection
		o = s.option(form.ListValue, 'sync_method', _('Sync Method'),
			_('owsync: real-time file synchronization. none: disable file synchronization.'));
		o.value('owsync', _('owsync'));
		o.value('none', _('none'));
		o.default = 'owsync';
		o.rmempty = false;

		// Sync DHCP Configuration - maps to service.dhcp.enabled
		o = s.option(form.Flag, '_dhcp_config', _('Sync DHCP Configuration'),
			_('Synchronize /etc/config/dhcp (address pools, static leases, DNS settings)'));
		o.default = '1';
		o.rmempty = false;
		o.cfgvalue = function() { return uci.get('ha-cluster', 'dhcp', 'enabled'); };
		o.write = function(section_id, value) { uci.set('ha-cluster', 'dhcp', 'enabled', value); };
		o.remove = function() { uci.set('ha-cluster', 'dhcp', 'enabled', '0'); };

		// Sync Firewall - maps to service.firewall.enabled
		o = s.option(form.Flag, '_firewall_config', _('Sync Firewall Rules'),
			_('Synchronize /etc/config/firewall (port forwarding, rules, zones). Review rules before enabling.'));
		o.default = '0';
		o.rmempty = false;
		o.cfgvalue = function() { return uci.get('ha-cluster', 'firewall', 'enabled'); };
		o.write = function(section_id, value) { uci.set('ha-cluster', 'firewall', 'enabled', value); };
		o.remove = function() { uci.set('ha-cluster', 'firewall', 'enabled', '0'); };

		// Sync Wireless - maps to service.wireless.enabled
		o = s.option(form.Flag, '_wireless_config', _('Sync Wireless Configuration'),
			_('Synchronize /etc/config/wireless (SSID, encryption). WARNING: Only enable if routers have identical WiFi hardware!'));
		o.default = '0';
		o.rmempty = false;
		o.cfgvalue = function() { return uci.get('ha-cluster', 'wireless', 'enabled'); };
		o.write = function(section_id, value) { uci.set('ha-cluster', 'wireless', 'enabled', value); };
		o.remove = function() { uci.set('ha-cluster', 'wireless', 'enabled', '0'); };

		return m.render();
	}
});
