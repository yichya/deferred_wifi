# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=deferred-wifi
PKG_VERSION:=0.0.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/deferred-wifi
	SECTION:=Custom
	CATEGORY:=Extra packages
	TITLE:=deferred-wifi
	MAINTAINER:=yichya <mail@yichya.dev>
endef

define Package/deferred-wifi/description
	Start wireless device after init is completed
endef

define Build/Compile
endef

define Package/deferred-wifi/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./deferred_wifi $(1)/etc/init.d/deferred_wifi
	$(INSTALL_DIR) $(1)/usr/share/deferred_wifi
	$(INSTALL_BIN) ./watchcat_restart.sh $(1)/usr/share/deferred_wifi/watchcat_restart.sh
endef

$(eval $(call BuildPackage,deferred-wifi))
