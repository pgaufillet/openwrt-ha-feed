# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2006-2016 OpenWrt.org
# Copyright (C) 2026 Pierre Gaufillet

include $(TOPDIR)/rules.mk

PKG_NAME:=dnsmasq-ha
PKG_UPSTREAM_NAME:=dnsmasq
PKG_UPSTREAM_VERSION:=2.90
PKG_VERSION:=$(subst test,~~test,$(subst rc,~rc,$(PKG_UPSTREAM_VERSION)))
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_UPSTREAM_NAME)-$(PKG_UPSTREAM_VERSION).tar.xz
PKG_SOURCE_URL:=https://thekelleys.org.uk/dnsmasq/
PKG_HASH:=8e50309bd837bfec9649a812e066c09b6988b73d749b7d293c06c57d46a109e4

PKG_LICENSE:=GPL-2.0
PKG_LICENSE_FILES:=COPYING
PKG_CPE_ID:=cpe:/a:thekelleys:dnsmasq

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_UPSTREAM_VERSION)

PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=lto
PKG_ASLR_PIE_REGULAR:=1

include $(INCLUDE_DIR)/package.mk

define Build/Prepare
	$(PKG_UNPACK)
	rm -rf $(PKG_BUILD_DIR)
	mv $(BUILD_DIR)/$(PKG_UPSTREAM_NAME)-$(PKG_UPSTREAM_VERSION) $(PKG_BUILD_DIR)
	$(Build/Patch)
endef

define Package/dnsmasq-ha
  SECTION:=net
  CATEGORY:=Base system
  TITLE:=DNS and DHCP server (HA Enabled)
  URL:=http://www.thekelleys.org.uk/dnsmasq/
  DEPENDS:=+libubus +libnettle +kmod-ipt-ipset +libnetfilter-conntrack +nftables-json
  PROVIDES:=dnsmasq
  USERID:=dnsmasq=453:dnsmasq=453
endef

define Package/dnsmasq-ha/description
  Replaces the stock dnsmasq with a version adding UBUS methods (add_lease,
  delete_lease, get_leases) required for HA DHCP lease synchronization.
  Cannot be installed alongside dnsmasq or dnsmasq-full.
endef

define Package/dnsmasq-ha/conffiles
/etc/config/dhcp
/etc/dnsmasq.conf
/etc/dnsmasq.d/
endef

# Hardcode options for HA variant (equivalent to full)
COPTS = -DHAVE_UBUS -DHAVE_POLL_H \
	$(if $(CONFIG_IPV6),,-DNO_IPV6) \
	-DHAVE_DNSSEC \
	-DHAVE_NFTSET \
	-DHAVE_CONNTRACK \
	-DNO_ID \
	-DNO_TFTP

MAKE_FLAGS := \
	$(TARGET_CONFIGURE_OPTS) \
	CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS)" \
	COPTS="$(COPTS)" \
	PREFIX="/usr"

define Package/dnsmasq-ha/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(CP) $(PKG_INSTALL_DIR)/usr/sbin/dnsmasq $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/dhcp.conf $(1)/etc/config/dhcp
	$(INSTALL_CONF) ./files/dnsmasq.conf $(1)/etc/dnsmasq.conf
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/dnsmasq.init $(1)/etc/init.d/dnsmasq
	$(INSTALL_DIR) $(1)/etc/hotplug.d/dhcp
	$(INSTALL_DIR) $(1)/etc/hotplug.d/neigh
	$(INSTALL_DIR) $(1)/etc/hotplug.d/ntp
	$(INSTALL_DIR) $(1)/etc/hotplug.d/tftp
	$(INSTALL_DATA) ./files/dnsmasqsec.hotplug $(1)/etc/hotplug.d/ntp/25-dnsmasqsec
	$(INSTALL_DIR) $(1)/usr/share/dnsmasq
	$(INSTALL_CONF) ./files/dhcpbogushostname.conf $(1)/usr/share/dnsmasq/
	$(INSTALL_CONF) ./files/rfc6761.conf $(1)/usr/share/dnsmasq/
	$(INSTALL_DIR) $(1)/usr/lib/dnsmasq
	$(INSTALL_BIN) ./files/dhcp-script.sh $(1)/usr/lib/dnsmasq/dhcp-script.sh
	$(INSTALL_DIR) $(1)/usr/share/acl.d
	$(INSTALL_DATA) ./files/dnsmasq_acl.json $(1)/usr/share/acl.d/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/50-dnsmasq-migrate-resolv-conf-auto.sh $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/50-dnsmasq-migrate-ipset.sh $(1)/etc/uci-defaults
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/trust-anchors.conf $(1)/usr/share/dnsmasq
endef

$(eval $(call BuildPackage,dnsmasq-ha))