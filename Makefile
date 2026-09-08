# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=deferred-wifi
PKG_VERSION:=0.0.4
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/deferred-wifi
	SECTION:=Custom
	CATEGORY:=Extra packages
	TITLE:=deferred-wifi
	MAINTAINER:=yichya <mail@yichya.dev>
	DEPENDS:= +@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT +@DRIVER_11BE_SUPPORT
endef

define Package/deferred-wifi/description
	Start wireless device after init is completed
endef

define Build/Compile
endef

define Package/deferred-wifi/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./deferred_wifi $(1)/etc/init.d/deferred_wifi
	$(INSTALL_DIR) $(1)/usr/share/watchcat
	$(INSTALL_BIN) ./watchcat_restart.sh $(1)/usr/share/watchcat/restart_interface.sh
	$(INSTALL_BIN) ./killall_usr2_odhcp6c.sh $(1)/usr/share/watchcat/killall_usr2_odhcp6c.sh
	$(INSTALL_BIN) ./service_network_restart.sh $(1)/usr/share/watchcat/service_network_restart.sh
endef

$(eval $(call BuildPackage,deferred-wifi))
