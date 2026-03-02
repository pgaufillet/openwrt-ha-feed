/*
 * Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
 * SPDX-License-Identifier: Apache-2.0
 */
'use strict';
'require view';
'require form';
'require uci';
'require ui';

return view.extend({
	load: function() {
		return uci.load('ha-cluster');
	},

	handleExclusionRemove: function(pattern, ev) {
		var excludeSections = uci.sections('ha-cluster', 'exclude');
		if (excludeSections.length === 0) return;

		var sectionId = excludeSections[0]['.name'];
		var files = uci.get('ha-cluster', sectionId, 'file') || [];
		if (!Array.isArray(files)) files = files ? [files] : [];

		var idx = files.indexOf(pattern);
		if (idx !== -1) {
			files.splice(idx, 1);
			uci.set('ha-cluster', sectionId, 'file', files);
			// Remove chip from DOM
			var chip = ev.currentTarget.parentNode;
			if (chip) chip.remove();
		}
	},

	handleExclusionAdd: function(ev) {
		var input = document.getElementById('new-exclusion-input');
		var pattern = (input.value || '').trim();

		if (!pattern) {
			ui.addNotification(null, E('p', _('Please enter an exclusion pattern.')));
			return;
		}

		// Ensure exclude section exists
		var excludeSections = uci.sections('ha-cluster', 'exclude');
		var sectionId;
		if (excludeSections.length === 0) {
			sectionId = uci.add('ha-cluster', 'exclude');
		} else {
			sectionId = excludeSections[0]['.name'];
		}

		var files = uci.get('ha-cluster', sectionId, 'file') || [];
		if (!Array.isArray(files)) files = files ? [files] : [];

		if (files.indexOf(pattern) !== -1) {
			ui.addNotification(null, E('p', _('Pattern already exists.')));
			return;
		}

		files.push(pattern);
		uci.set('ha-cluster', sectionId, 'file', files);

		// Add chip to DOM
		var container = document.getElementById('exclusion-chips');
		container.appendChild(this.renderChip(pattern));
		input.value = '';
	},

	renderChip: function(pattern) {
		return E('span', {
			'class': 'label',
			'style': 'display: inline-flex; align-items: center; margin: 2px 4px 2px 0; padding: 4px 8px; background: #f0f0f0; border-radius: 12px; font-family: monospace; font-size: 12px;'
		}, [
			E('span', {}, pattern),
			E('button', {
				'type': 'button',
				'style': 'border: none; background: transparent; cursor: pointer; margin-left: 6px; padding: 0; font-size: 14px; color: #666; line-height: 1;',
				'click': ui.createHandlerFn(this, 'handleExclusionRemove', pattern),
				'title': _('Remove')
			}, '\u00d7')
		]);
	},

	render: function() {
		var m, s, o;
		var self = this;
		var baseServices = ['dhcp', 'firewall', 'dns', 'wireless', 'vpn'];

		m = new form.Map('ha-cluster', _('High Availability - Advanced Config Sync'),
			_('Custom sync groups for services beyond General settings (e.g., VPN, mwan3).'));

		// === Global Settings ===
		s = m.section(form.TypedSection, 'advanced', _('Global Settings'),
			_('owsync global options.'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'sync_interval', _('Poll Interval (seconds)'),
			_('Fallback scan interval. Changes are also detected via inotify events.'));
		o.datatype = 'uinteger';
		o.placeholder = '30';
		o.default = '30';

		o = s.option(form.ListValue, 'owsync_log_level', _('Log Level'),
			_('Verbosity of owsync daemon logging.'));
		o.value('0', _('Error'));
		o.value('1', _('Warning'));
		o.value('2', _('Info (default)'));
		o.value('3', _('Debug'));
		o.default = '2';

		// === Additional Sync Groups ===
		s = m.section(form.GridSection, 'service', _('Additional Sync Groups'),
			_('Click Edit to configure files.'));
		s.anonymous = false;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;

		// Filter out base services - they are managed in General
		s.filter = function(section_id) {
			return baseServices.indexOf(section_id) === -1;
		};

		o = s.option(form.DummyValue, '_enabled_status', _('Status'));
		o.textvalue = function(section_id) {
			var enabled = uci.get('ha-cluster', section_id, 'enabled');
			if (enabled === '1' || enabled === true) {
				return E('span', { 'class': 'cbi-value-field' }, [
					E('span', { 'class': 'label success' }, _('Enabled'))
				]);
			} else {
				return E('span', { 'class': 'cbi-value-field' }, [
					E('span', { 'class': 'label' }, _('Disabled'))
				]);
			}
		};
		o.modalonly = false;

		o = s.option(form.DummyValue, '_files_count', _('Files'));
		o.textvalue = function(section_id) {
			var files = uci.get('ha-cluster', section_id, 'config_files') || [];
			if (!Array.isArray(files)) files = files ? [files] : [];
			return E('span', { 'class': 'cbi-value-field' }, files.length + ' ' + _('configured'));
		};
		o.modalonly = false;

		o = s.option(form.Flag, 'enabled', _('Enable Sync'),
			_('Enable synchronization for this group.'));
		o.default = '1';
		o.modalonly = true;

		o = s.option(form.DynamicList, 'config_files', _('Files/Directories to Sync'),
			_('UCI names (e.g., "openvpn") or absolute paths (e.g., "/etc/openvpn/keys").'));
		o.datatype = 'string';
		o.placeholder = 'openvpn or /etc/openvpn/keys';
		o.modalonly = true;

		// Render form.Map, then append exclusions section
		return m.render().then(L.bind(function(mapEl) {
			// Get current exclusions
			var excludeSections = uci.sections('ha-cluster', 'exclude');
			var exclusions = [];
			if (excludeSections.length > 0) {
				var files = uci.get('ha-cluster', excludeSections[0]['.name'], 'file') || [];
				if (!Array.isArray(files)) files = files ? [files] : [];
				exclusions = files;
			}

			// Build exclusions section with chip/tag UI
			var chipsContainer = E('div', {
				'id': 'exclusion-chips',
				'style': 'display: flex; flex-wrap: wrap; align-items: center; min-height: 32px; padding: 8px 0; margin-bottom: 8px;'
			});

			exclusions.forEach(L.bind(function(pattern) {
				chipsContainer.appendChild(this.renderChip(pattern));
			}, this));

			if (exclusions.length === 0) {
				chipsContainer.appendChild(E('span', {
					'class': 'cbi-value-description',
					'style': 'font-style: italic; color: #888;'
				}, _('No additional exclusions configured')));
			}

			var exclusionsSection = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Exclusions')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Files excluded by default: network, system, ha-cluster, owsync. Add patterns below.')),
				E('div', { 'class': 'cbi-section-node' }, [
					chipsContainer,
					E('div', { 'class': 'cbi-section-create' }, [
						E('div', {}, [
							E('input', {
								'type': 'text',
								'class': 'cbi-section-create-name',
								'id': 'new-exclusion-input',
								'placeholder': '/etc/dropbear/*.key'
							})
						]),
						E('button', {
							'class': 'cbi-button cbi-button-add',
							'click': ui.createHandlerFn(this, 'handleExclusionAdd')
						}, _('Add'))
					])
				])
			]);

			mapEl.appendChild(exclusionsSection);
			return mapEl;
		}, this)).catch(function(err) {
			ui.addNotification(null,
				E('p', {}, _('Failed to render configuration: ') + err.message),
				'danger');
			return E('div', { 'class': 'cbi-map-error' },
				E('p', {}, _('Error loading page. Please try refreshing.')));
		});
	}
});
