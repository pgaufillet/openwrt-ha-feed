/*
 * Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
 * SPDX-License-Identifier: Apache-2.0
 */
'use strict';
'require view';
'require form';
'require uci';
'require network';
'require fs';
'require ui';

var hooksPath = '/etc/hotplug.d/keepalived';
var systemHook = '50-ha-cluster';

var hookTemplate = '#!/bin/sh\n' +
	'# Keepalived state change hook\n' +
	'# Environment: $ACTION (MASTER/BACKUP/FAULT/STOP), $NAME (instance), $TYPE\n' +
	'\n' +
	'[ "$TYPE" = "INSTANCE" ] || exit 0\n' +
	'\n' +
	'case "$ACTION" in\n' +
	'    MASTER)\n' +
	'        # Actions when becoming MASTER\n' +
	'        ;;\n' +
	'    BACKUP)\n' +
	'        # Actions when becoming BACKUP\n' +
	'        ;;\n' +
	'    FAULT)\n' +
	'        # Actions on fault\n' +
	'        ;;\n' +
	'esac\n' +
	'\n' +
	'exit 0\n';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ha-cluster'),
			network.getDevices(),
			L.resolveDefault(fs.list(hooksPath), [])
		]);
	},

	currentHookData: null,

	handleHookEdit: function(filename, content, isEnabled, ev) {
		this.currentHookData = { filename: filename, content: content, isEnabled: isEnabled };

		// Use template if content is empty or just whitespace
		var displayContent = (content && content.trim()) ? content : hookTemplate;

		ui.showModal(_('Edit Hook: %s').format(filename), [
			E('p', {}, _('Shell script executed on VRRP state changes. Environment variables: $ACTION, $NAME, $TYPE.')),
			E('textarea', {
				'id': 'modal-hook-content',
				'rows': 20,
				'wrap': 'off'
			}, displayContent),
			E('p', {}, [
				E('label', {}, [
					E('input', {
						'type': 'checkbox',
						'id': 'modal-hook-enabled',
						'checked': isEnabled
					}),
					' ',
					_('Enabled (executable)')
				])
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleHookDeleteFromModal', filename)
				}, _('Delete')),
				' ',
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, 'handleHookSaveFromModal', filename)
				}, _('Save'))
			])
		]);
	},

	handleHookSaveFromModal: function(filename, ev) {
		var textarea = document.getElementById('modal-hook-content');
		var enabledCheckbox = document.getElementById('modal-hook-enabled');
		var content = (textarea.value || '').trim().replace(/\r\n/g, '\n') + '\n';
		var shouldBeEnabled = enabledCheckbox.checked;
		var filepath = hooksPath + '/' + filename;

		return fs.write(filepath, content).then(function() {
			return fs.exec('/bin/chmod', [shouldBeEnabled ? '+x' : '-x', filepath]);
		}).then(function() {
			ui.hideModal();
			ui.addNotification(null, E('p', _('Hook "%s" saved.').format(filename)), 'info');
			// Update grid row
			var statusBadge = document.querySelector('[data-hook="' + CSS.escape(filename) + '"] .hook-status');
			if (statusBadge) {
				statusBadge.textContent = shouldBeEnabled ? _('Enabled') : _('Disabled');
				statusBadge.className = 'hook-status label ' + (shouldBeEnabled ? 'success' : '');
			}
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Unable to save hook: %s').format(e.message)));
		});
	},

	handleHookDeleteFromModal: function(filename, ev) {
		if (!confirm(_('Delete hook "%s"?').format(filename)))
			return;

		var filepath = hooksPath + '/' + filename;

		return fs.remove(filepath).then(function() {
			ui.hideModal();
			var row = document.querySelector('[data-hook="' + CSS.escape(filename) + '"]');
			if (row) row.remove();
			ui.addNotification(null, E('p', _('Hook "%s" deleted.').format(filename)), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Unable to delete hook: %s').format(e.message)));
		});
	},

	handleHookAdd: function(ev) {
		var nameInput = document.getElementById('new-hook-name');
		var filename = (nameInput.value || '').trim();

		if (!filename) {
			ui.addNotification(null, E('p', _('Please enter a hook name.')));
			return;
		}

		// Validate filename (alphanumeric, dash, underscore)
		if (!/^[a-zA-Z0-9_-]+$/.test(filename)) {
			ui.addNotification(null, E('p', _('Hook name must contain only letters, numbers, dashes, and underscores.')));
			return;
		}

		var filepath = hooksPath + '/' + filename;

		return fs.write(filepath, hookTemplate).then(function() {
			return fs.exec('/bin/chmod', ['+x', filepath]);
		}).then(function() {
			nameInput.value = '';
			ui.addNotification(null, E('p', _('Hook "%s" created. Reload page to edit.').format(filename)), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Unable to create hook: %s').format(e.message)));
		});
	},

	renderHookRow: function(file, content) {
		var filename = file.name;
		var isEnabled = !!(file.mode & 0o100);

		return E('tr', { 'class': 'tr', 'data-hook': filename }, [
			E('td', { 'class': 'td' }, filename),
			E('td', { 'class': 'td' }, [
				E('span', {
					'class': 'hook-status label ' + (isEnabled ? 'success' : '')
				}, isEnabled ? _('Enabled') : _('Disabled'))
			]),
			E('td', { 'class': 'td cbi-section-actions' }, [
				E('button', {
					'class': 'btn cbi-button-edit',
					'click': ui.createHandlerFn(this, 'handleHookEdit', filename, content, isEnabled),
					'title': _('Edit')
				}, _('Edit'))
			])
		]);
	},

	render: function(data) {
		var netDevs = data[1] || [];
		var hookFiles = (data[2] || []).filter(function(f) {
			return f.name !== systemHook && f.type === 'file';
		});
		var scriptSections = uci.sections('ha-cluster', 'script') || [];
		var m, s, o;
		var self = this;

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

		m = new form.Map('ha-cluster', _('High Availability - Advanced VRRP'),
			_('Advanced VRRP tuning. Interface, IP, Netmask, and VRID are in General.'));

		// === Global Settings ===
		s = m.section(form.TypedSection, 'advanced', _('Global Settings'),
			_('Keepalived global options and email notifications.'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'max_auto_priority', _('Max Auto Priority'),
			_('Set to 0 to disable auto-priority (recommended).'));
		o.datatype = 'uinteger';
		o.placeholder = '0';
		o.default = '0';

		o = s.option(form.ListValue, 'log_level', _('HA Cluster Log Level'),
			_('Verbosity of ha-cluster shell scripts logging.'));
		o.value('0', _('Error'));
		o.value('1', _('Warning'));
		o.value('2', _('Info (default)'));
		o.value('3', _('Debug'));
		o.default = '2';

		o = s.option(form.Flag, 'enable_notifications', _('Enable Email Notifications'),
			_('Send email on state changes. Requires SMTP server.'));
		o.default = '0';

		o = s.option(form.DynamicList, 'notification_email', _('Recipient Emails'));
		o.depends('enable_notifications', '1');
		o.placeholder = 'admin@example.com';

		o = s.option(form.Value, 'notification_email_from', _('From Email'));
		o.depends('enable_notifications', '1');
		o.placeholder = 'ha-cluster@router.local';

		o = s.option(form.Value, 'smtp_server', _('SMTP Server'));
		o.depends('enable_notifications', '1');
		o.placeholder = '192.168.1.100';

		// === Virtual IP Addresses ===
		s = m.section(form.GridSection, 'vip', _('Virtual IP Addresses'),
			_('Click Edit for advanced settings.'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.tab('timing', _('Timing'));
		s.tab('auth', _('Authentication'));
		s.tab('tracking', _('Tracking'));
		s.tab('unicast', _('Unicast'));

		o = s.option(form.DummyValue, '_interface', _('Interface'));
		o.textvalue = function(section_id) {
			var ifname = uci.get('ha-cluster', section_id, 'interface') || '';
			var vipname = section_id || '';
			return E('span', {}, [
				E('img', { 'src': ifaceIconUrl(ifname), 'style': 'width:24px;height:24px;vertical-align:middle;margin-right:6px' }),
				E('span', {}, (vipname ? vipname + ' ' : '') + (ifname ? '(' + ifname + ')' : '-'))
			]);
		};
		o.modalonly = false;

		o = s.option(form.DummyValue, '_address', _('Virtual IP Address'));
		o.textvalue = function(section_id) {
			var addr = uci.get('ha-cluster', section_id, 'address') || '';
			var addr6 = uci.get('ha-cluster', section_id, 'address6') || '';
			if (addr && addr6)
				return addr + ', ' + addr6;
			return addr || addr6 || '-';
		};

		// === Timing Tab ===
		o = s.taboption('timing', form.Value, 'advert_int', _('Advertisement Interval'),
			_('VRRP advertisement frequency (seconds). Lower = faster failover. Default: 1.'));
		o.datatype = 'float';
		o.placeholder = '1.0';
		o.default = '1';
		o.modalonly = true;

		o = s.taboption('timing', form.Value, 'priority', _('VIP-Specific Priority'),
			_('Override global priority for this VIP. Leave empty for global priority.'));
		o.datatype = 'range(1,255)';
		o.placeholder = _('Use global priority');
		o.optional = true;
		o.modalonly = true;

		o = s.taboption('timing', form.Flag, 'nopreempt', _('Keep Current MASTER (disable preemption)'),
			_('Current MASTER stays MASTER even if higher-priority router returns.'));
		o.default = '1';
		o.modalonly = true;

		o = s.taboption('timing', form.Value, 'preempt_delay', _('Preempt Delay'),
			_('Seconds before higher-priority router takes over. Prevents flapping. Recommended: 30-60.'));
		o.datatype = 'uinteger';
		o.placeholder = '30';
		o.optional = true;
		o.modalonly = true;

		o = s.taboption('timing', form.Value, 'garp_master_delay', _('GARP Delay'),
			_('Seconds before sending Gratuitous ARP after becoming MASTER. Helps with slow switches. Default: 5.'));
		o.datatype = 'uinteger';
		o.placeholder = '5';
		o.optional = true;
		o.modalonly = true;

		// === Authentication Tab ===
		o = s.taboption('auth', form.ListValue, 'auth_type', _('Authentication Type'),
			_('PASS: basic (max 8 chars, cleartext). AH: cryptographic (requires kmod-ipsec).'));
		o.value('none', _('None'));
		o.value('pass', _('Simple Password (PASS)'));
		o.value('ah', _('IPSec AH'));
		o.default = 'none';
		o.modalonly = true;
		o.cfgvalue = function(section_id) {
			var v = uci.get('ha-cluster', section_id, 'auth_type') || 'none';
			if (v && !(this.keylist || []).includes(v)) {
				this.value(v, v);
			}
			return v;
		};

		o = s.taboption('auth', form.Value, 'auth_pass', _('Authentication Password'),
			_('Shared secret (4-8 chars). Must be identical on all nodes.'));
		o.password = true;
		o.datatype = 'and(minlength(4),maxlength(8))';
		o.placeholder = _('4-8 characters');
		o.depends('auth_type', 'pass');
		o.modalonly = true;

		// === Tracking Tab ===
		o = s.taboption('tracking', form.DynamicList, 'track_interface', _('Track Interfaces'),
			_('Failover when tracked interface goes DOWN. Common: track WAN for internet failover.'));
		netDevs.forEach(function(dev) {
			if (dev.getName) {
				o.value(dev.getName());
			}
		});
		o.placeholder = _('Select interface');
		o.modalonly = true;

		o = s.taboption('tracking', form.DynamicList, 'track_script', _('Track Scripts'),
			_('Failover when health check fails. Define scripts in Health Checks section below.'));
		scriptSections.forEach(function(script) {
			if (script['.name']) {
				o.value(script['.name']);
			}
		});
		o.placeholder = _('Select script');
		o.modalonly = true;

		// === Unicast Tab ===
		o = s.taboption('unicast', form.Value, 'unicast_src_ip', _('Unicast Source IP'),
			_('This router\'s IP for unicast VRRP. Leave empty for multicast (default).'));
		o.datatype = 'ipaddr';
		o.placeholder = _('e.g., 192.168.1.1');
		o.optional = true;
		o.modalonly = true;

		o = s.taboption('unicast', form.DynamicList, 'unicast_peer', _('Unicast Peer IPs'),
			_('Peer router IPs. Required when using unicast mode. Both src_ip and peer must be set.'));
		o.datatype = 'ipaddr';
		o.placeholder = _('e.g., 192.168.1.2');
		o.modalonly = true;

		// === Health Checks (VRRP Scripts) ===
		s = m.section(form.GridSection, 'script', _('Health Checks (VRRP Scripts)'),
			_('Custom checks referenced by track_script. Examples: ping gateway, check DNS, verify VPN.'));
		s.anonymous = false;
		s.addremove = true;
		s.sortable = true;

		o = s.option(form.DummyValue, '_script', _('Script'));
		o.cfgvalue = function(section_id) { return uci.get('ha-cluster', section_id, 'script') || '-'; };
		o.modalonly = false;

		o = s.option(form.Value, 'script', _('Script Command'),
			_('Command returning 0 for success. Use absolute paths.'));
		o.placeholder = '/bin/ping -c 1 -W 1 8.8.8.8';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'interval', _('Interval'),
			_('Seconds between checks.'));
		o.datatype = 'uinteger';
		o.placeholder = '5';
		o.default = '5';
		o.modalonly = true;

		o = s.option(form.Value, 'timeout', _('Timeout'),
			_('Max seconds for script.'));
		o.datatype = 'uinteger';
		o.placeholder = '2';
		o.optional = true;
		o.modalonly = true;

		o = s.option(form.Value, 'weight', _('Weight'),
			_('Priority adjustment on failure (e.g., -10).'));
		o.datatype = 'integer';
		o.placeholder = '-10';
		o.optional = true;
		o.modalonly = true;

		o = s.option(form.Value, 'rise', _('Rise'),
			_('Successes before healthy.'));
		o.datatype = 'uinteger';
		o.placeholder = '2';
		o.optional = true;
		o.modalonly = true;

		o = s.option(form.Value, 'fall', _('Fall'),
			_('Failures before unhealthy.'));
		o.datatype = 'uinteger';
		o.placeholder = '2';
		o.optional = true;
		o.modalonly = true;

		o = s.option(form.Value, 'user', _('User'),
			_('Run as user (default: root).'));
		o.datatype = 'and(minlength(1),maxlength(32))';
		o.placeholder = 'nobody';
		o.optional = true;
		o.modalonly = true;

		// Render form.Map, then append hooks section
		return m.render().then(L.bind(function(mapEl) {
			// Load hook file contents
			var readPromises = hookFiles.map(function(file) {
				return L.resolveDefault(fs.read(hooksPath + '/' + file.name), '').then(function(content) {
					return { file: file, content: content };
				});
			});

			return Promise.all(readPromises).then(L.bind(function(hooks) {
				// Build hooks section with grid
				var hooksTable = E('table', { 'class': 'table cbi-section-table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Name')),
						E('th', { 'class': 'th' }, _('Status')),
						E('th', { 'class': 'th cbi-section-actions' }, '')
					])
				]);

				var tbody = E('tbody', { 'id': 'hooks-tbody' });
				hooks.forEach(L.bind(function(h) {
					tbody.appendChild(this.renderHookRow(h.file, h.content));
				}, this));

				if (hooks.length === 0) {
					tbody.appendChild(E('tr', { 'class': 'tr placeholder' }, [
						E('td', { 'class': 'td', 'colspan': '3', 'style': 'text-align: center; font-style: italic; color: #888;' },
							_('No custom hooks defined.'))
					]));
				}

				hooksTable.appendChild(tbody);

				var hooksContainer = E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('State Change Hooks')),
					E('div', { 'class': 'cbi-section-descr' },
						_('Shell scripts executed on VRRP state changes. Click Edit to modify. Environment: $ACTION, $NAME, $TYPE.')),
					hooksTable,
					E('div', { 'class': 'cbi-section-create' }, [
						E('div', {}, [
							E('input', {
								'type': 'text',
								'class': 'cbi-section-create-name',
								'id': 'new-hook-name',
								'placeholder': _('e.g., 60-vpn-failover')
							})
						]),
						E('button', {
							'class': 'cbi-button cbi-button-add',
							'click': ui.createHandlerFn(this, 'handleHookAdd')
						}, _('Add'))
					])
				]);

				mapEl.appendChild(hooksContainer);
				return mapEl;
			}, this));
		}, this));
	}
});
