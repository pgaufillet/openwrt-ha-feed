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
			L.resolveDefault(fs.stat('/usr/sbin/lease-sync'), null),
			L.resolveDefault(fs.stat('/usr/bin/owsync'), null)
		]);
	},

	render: function(data) {
		var interfaces = data[1] || [];
		var netDevs = data[2] || [];
		var leaseSyncInstalled = data[3] != null;
		var owsyncInstalled = data[4] != null;
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

		// Deterministic VRID from instance name (DJB2 hash, range 1-127)
		var computeVrid = function(ifname) {
			var hash = 5381;
			for (var i = 0; i < ifname.length; i++)
				hash = ((hash << 5) + hash + ifname.charCodeAt(i)) & 0xffffffff;
			return ((hash >>> 0) % 127) + 1;
		};

		// UCI boolean as read by config_get_bool
		var getBool = function(value, dflt) {
			if (['1', 'on', 'true', 'yes', 'enabled'].indexOf(value) !== -1)
				return true;
			if (['0', 'off', 'false', 'no', 'disabled'].indexOf(value) !== -1)
				return false;
			return dflt;
		};

		var groupEnabled = function(group) {
			return getBool(group.enabled, true);
		};

		var installHint = function(text) {
			return E('div', { 'class': 'alert-message' }, [
				E('p', {}, text),
				E('p', {}, E('a', { 'href': '/cgi-bin/luci/admin/system/package-manager' },
					_('Go to Software page') + ' \u2192'))
			]);
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

		o = s.option(form.ListValue, 'vrrp_transport', _('VRRP Transport'),
			_('Multicast is the default. Use unicast when multicast is unavailable on the network.'));
		o.value('multicast', _('Multicast'));
		o.value('unicast', _('Unicast'));
		o.default = 'multicast';
		o.rmempty = false;

		// Peer Configuration
		s = m.section(form.GridSection, 'peer', _('Peer Routers'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		// Custom handleAdd following DDNS pattern:
		// 1. Show modal with separate form.Map (isolated from main form)
		// 2. On Add: save main form first (preserves pending changes like node_priority)
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

			var peerSyncEnabled = s2.option(form.Flag, 'sync_enabled', _('Enable Synchronization'),
				_('When disabled, this peer participates in VRRP failover but is excluded from config and lease sync. Use for non-OpenWrt peers.'));
			peerSyncEnabled.default = '1';

			m2.render().then(function(nodes) {
				ui.showModal(_('Add Peer Router'), [
					nodes,
					E('div', { 'class': 'right' }, [
						E('button', {
							'type': 'button',
							'class': 'btn',
							'click': ui.hideModal
						}, _('Cancel')), ' ',
						E('button', {
							'type': 'button',
							'class': 'cbi-button cbi-button-positive',
							'click': function() {
								var nameVal = peerName.formvalue('_new_');
								var addrVal = peerAddress.formvalue('_new_');
								var sourceVal = peerSource.formvalue('_new_');
								var syncVal = peerSyncEnabled.formvalue('_new_');

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
									uci.set('ha-cluster', newSection, 'sync_enabled', syncVal || '1');
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

		o = s.option(form.Flag, 'sync_enabled', _('Enable Synchronization'),
			_('When disabled, this peer participates in VRRP failover but is excluded from config and lease sync. Use for non-OpenWrt peers.'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		// Virtual IP Configuration
		s = m.section(form.GridSection, 'vip', _('Virtual IP Addresses'),
			_('All VIPs share a single failover group and switch together. Use the Advanced page to create independent failover groups.') + ' ' +
			_('Optional. If IPv6 is configured, keepalived creates a second instance with VRID+128.'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.addbtntitle = _('Add VIP...');

		// Garbage collection: remove orphaned vrrp_instance when last VIP is deleted
		s.handleRemove = function(section_id, ev) {
			var instName = uci.get('ha-cluster', section_id, 'vrrp_instance') || '';

			uci.remove('ha-cluster', section_id);

			if (instName) {
				var hasVips = uci.sections('ha-cluster', 'vip').some(function(vip) {
					return vip.vrrp_instance === instName;
				});
				if (!hasVips)
					uci.remove('ha-cluster', instName);
			}

			return this.map.save(null, true).catch(function(err) {
				ui.addNotification(null,
					E('p', {}, _('Failed to save: ') + err.message),
					'danger');
			});
		};

		o = s.option(form.DummyValue, '_interface_display', _('Interface'));
		o.textvalue = function(section_id) {
			var ifname = uci.get('ha-cluster', section_id, 'interface') || '';
			return E('span', {}, [
				E('img', { 'src': ifaceIconUrl(ifname), 'style': 'width:16px;height:16px;vertical-align:middle;margin-right:4px' }),
				E('span', {}, ifname || '-')
			]);
		};
		o.modalonly = false;

		o = s.option(form.DummyValue, '_vrid_display', _('VRID'));
		o.textvalue = function(section_id) {
			var inst = uci.get('ha-cluster', section_id, 'vrrp_instance') || '';
			if (!inst) return '-';
			var vrid = uci.get('ha-cluster', inst, 'vrid');
			if (!vrid) return '-';
			var addr6 = uci.get('ha-cluster', section_id, 'address6');
			if (addr6) {
				var vrid6 = parseInt(vrid, 10) + 128;
				return vrid + ' (IPv6: ' + vrid6 + ')';
			}
			return vrid;
		};
		o.modalonly = false;

		o = s.option(form.DummyValue, '_ipv4_display', _('IPv4 Address'));
		o.textvalue = function(section_id) {
			var addr = uci.get('ha-cluster', section_id, 'address');
			if (addr) return addr;
			return E('em', {}, _('none'));
		};
		o.modalonly = false;

		o = s.option(form.DummyValue, '_ipv6_display', _('IPv6 Address'));
		o.textvalue = function(section_id) {
			var addr6 = uci.get('ha-cluster', section_id, 'address6');
			if (addr6) return addr6;
			return E('em', {}, _('none'));
		};
		o.modalonly = false;

		o = s.option(form.DummyValue, '_enabled_display', _('Enable'));
		o.textvalue = function(section_id) {
			var en = uci.get('ha-cluster', section_id, 'enabled');
			return (en === '1' || en === true || en == null) ? _('Yes') : _('No');
		};
		o.modalonly = false;

		o = s.option(form.ListValue, 'interface', _('Interface'));
		o.rmempty = false;
		o.modalonly = true;
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
		o.write = function(section_id, value) {
			uci.set('ha-cluster', section_id, 'interface', value);

			// Ensure 'main' instance exists; attach VIP to it
			var instName = 'main';
			var exists = uci.sections('ha-cluster', 'vrrp_instance').some(function(inst) {
				return inst['.name'] === instName;
			});
			if (!exists) {
				var globalPriority = uci.get('ha-cluster', 'config', 'node_priority') || '100';
				// Default advertisement interface: 'lan' if available, else blank
				var defaultIface = '';
				var ifaceList = interfaces || [];
				for (var i = 0; i < ifaceList.length; i++) {
					if (ifaceList[i].interface === 'lan') { defaultIface = 'lan'; break; }
				}
				uci.add('ha-cluster', 'vrrp_instance', instName);
				uci.set('ha-cluster', instName, 'vrid', String(computeVrid(instName)));
				if (defaultIface)
					uci.set('ha-cluster', instName, 'interface', defaultIface);
				uci.set('ha-cluster', instName, 'priority', globalPriority);
				uci.set('ha-cluster', instName, 'nopreempt', '1');
				uci.set('ha-cluster', instName, 'advert_int', '1');
			}
			uci.set('ha-cluster', section_id, 'vrrp_instance', instName);
		};

		o = s.option(form.Value, 'address', _('Virtual IP Address (IPv4)'));
		o.datatype = 'ip4addr';
		o.placeholder = '192.168.1.254';
		o.rmempty = true;
		o.modalonly = true;
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
		o.description = _('Optional. If IPv6 is configured, keepalived creates a second instance with VRID+128.');
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

		// Synchronization: key, files (owsync), leases (lease-sync)
		s = m.section(form.NamedSection, 'config', 'global', _('Synchronization'),
			_('Keeps configuration files and DHCP leases identical on the cluster nodes. These settings must be the same on every node.'));

		// Encryption settings first
		// Setting a key enables AES-256-GCM for owsync and lease-sync; leaving
		// it empty runs sync in plaintext.
		var encryption_key_option = s.option(form.Value, 'encryption_key', _('Encryption Key'),
			_('256-bit AES key (64 hexadecimal characters), used for both configuration and lease sync. Must be identical on all nodes. Leave empty to sync in plaintext.'));
		encryption_key_option.password = true;
		encryption_key_option.datatype = 'and(hexstring,rangelength(64,64))';
		encryption_key_option.rmempty = true;
		encryption_key_option.placeholder = _('Click "Generate New Key" below to create a secure random key');

		o = s.option(form.Button, '_generate_key', _('Generate New Key'));
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
								E('li', {}, _('On each peer router, go to: HA Cluster → General → Synchronization Settings')),
								E('li', {}, _('Paste this key into the "Encryption Key" field')),
								E('li', {}, _('Save & Apply on all peer routers'))
							])
						]),
						E('div', { 'class': 'right' }, [
							E('button', {
								'type': 'button',
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

		var groups = uci.sections('ha-cluster', 'sync_group');

		s = m.section(form.NamedSection, 'config', 'global', _('Configuration Files'));

		if (owsyncInstalled) {
			// Maps to sync_group.<name>.enabled; the group is created when first enabled
			var groupFlag = function(name, title, description) {
				var o = s.option(form.Flag, '_group_' + name, title, description);
				o.rmempty = false;
				o.cfgvalue = function() {
					var group = uci.get('ha-cluster', name);
					return (group && groupEnabled(group)) ? '1' : '0';
				};
				o.write = function(section_id, value) {
					if (!uci.get('ha-cluster', name)) {
						if (value === '1') {
							uci.add('ha-cluster', 'sync_group', name);
							uci.set('ha-cluster', name, 'enabled', '1');
							uci.set('ha-cluster', name, 'config_files', [ name ]);
						}
					} else if (this.cfgvalue(section_id) !== value) {
						uci.set('ha-cluster', name, 'enabled', value);
					}
				};
				return o;
			};

			groupFlag('dhcp', _('DHCP and DNS'),
				_('<code>/etc/config/dhcp</code>: address pools, static leases, DNS settings.'));
			groupFlag('firewall', _('Firewall'),
				_('<code>/etc/config/firewall</code>: zones, rules, port forwards. Review the rules before enabling: they apply to every node.'));

			var others = groups.filter(function(group) {
				return group['.name'] !== 'dhcp' && group['.name'] !== 'firewall';
			});
			o = s.option(form.DummyValue, '_group_others', _('Other files'));
			o.renderWidget = function() {
				var enabled = others.filter(groupEnabled).length;
				return E('div', {}, [
					E('em', {}, others.length
						? N_(others.length, '%d group', '%d groups').format(others.length) + ' (' + _('%d enabled').format(enabled) + ')'
						: _('none')),
					' ',
					E('a', { 'href': L.url('admin/services/ha-cluster/owsync-advanced') }, _('Advanced Config Sync') + ' \u2192')
				]);
			};
		} else {
			var enabledGroups = groups.filter(groupEnabled).length;
			o = s.option(form.DummyValue, '_owsync_missing');
			o.renderWidget = function() {
				return installHint(_('owsync is not installed. Install the <code>owsync</code> package to synchronize configuration files.') +
					(enabledGroups ? ' ' + N_(enabledGroups,
						'The enabled sync group in the configuration will apply once it is installed.',
						'The %d enabled sync groups in the configuration will apply once it is installed.').format(enabledGroups) : ''));
			};
		}

		s = m.section(form.NamedSection, 'config', 'global', _('DHCP Leases'));

		if (leaseSyncInstalled) {
			o = s.option(form.Flag, 'lease_sync', _('Real-time Lease Sync'),
				_('Replicates DHCP leases between nodes so that clients keep their address after a failover. Independent of the DHCP configuration sync above.'));
			o.rmempty = false;
			o.cfgvalue = function(section_id) {
				return getBool(uci.get('ha-cluster', section_id, 'lease_sync'), false) ? '1' : '0';
			};
			o.write = function(section_id, value) {
				if (this.cfgvalue(section_id) !== value)
					uci.set('ha-cluster', section_id, 'lease_sync', value);
			};
		} else {
			o = s.option(form.DummyValue, '_lease_sync_missing');
			o.renderWidget = function(section_id) {
				return installHint(_('lease-sync is not installed. Install the <code>lease-sync</code> and <code>dnsmasq-ha</code> packages to synchronize DHCP leases.') +
					(getBool(uci.get('ha-cluster', section_id, 'lease_sync'), false)
						? ' ' + _('Lease sync is on in the configuration and will start once they are installed.') : ''));
			};
		}

		return m.render();
	}
});
