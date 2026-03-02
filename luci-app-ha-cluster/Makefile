include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for HA Cluster
LUCI_DEPENDS:=+ha-cluster +luci-base +rpcd

PKG_NAME:=luci-app-ha-cluster
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
