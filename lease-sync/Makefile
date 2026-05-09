# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

include $(TOPDIR)/rules.mk

PKG_NAME:=lease-sync
PKG_VERSION:=1.2.0
PKG_RELEASE:=5

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/pgaufillet/lease-sync.git
PKG_SOURCE_VERSION:=4594901d8ce2c55ded7be141f86e1ca74c4115ef
PKG_MIRROR_HASH:=skip

PKG_MAINTAINER:=Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/lease-sync
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=DHCP Lease Synchronization Daemon
  DEPENDS:=+libubus +libubox +libopenssl +dnsmasq-ha
endef

define Package/lease-sync/description
  High-availability DHCP lease synchronization daemon for dnsmasq.
  Enables active/active HA clusters by synchronizing DHCP leases
  between multiple dnsmasq instances via ubus and UDP.
endef

define Package/lease-sync/conffiles
/etc/config/lease-sync
/etc/lease-sync/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR)/daemon \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)" \
		LIBS="-lubus -lubox -lssl -lcrypto" \
		STATEDIR="/etc/lease-sync"
endef

define Package/lease-sync/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/daemon/lease-sync $(1)/usr/sbin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/lease-sync.init $(1)/etc/init.d/lease-sync

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/lease-sync.config $(1)/etc/config/lease-sync

	$(INSTALL_DIR) $(1)/etc/lease-sync

	$(INSTALL_DIR) $(1)/etc/hotplug.d/dhcp
	$(INSTALL_BIN) ./files/lease-sync.hotplug $(1)/etc/hotplug.d/dhcp/50-lease-sync

endef

define Package/lease-sync/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/lease-sync stop >/dev/null 2>&1
	/etc/init.d/lease-sync disable >/dev/null 2>&1
fi
exit 0
endef

define Package/lease-sync/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/lease-sync enable
	echo "NOTE: Restart dnsmasq to activate the DHCP hotplug handler:"
	echo "  /etc/init.d/dnsmasq restart"
}
exit 0
endef

$(eval $(call BuildPackage,lease-sync))
