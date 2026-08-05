include $(TOPDIR)/rules.mk

PKG_NAME:=sbe1v1k-full-defaults
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe1v1k-full-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Safe service defaults for the SBE1V1K full image
endef

define Package/sbe1v1k-full-defaults/description
  Keeps optional server components disabled until the administrator explicitly
  configures and enables them.
endef

define Build/Compile
endef

define Package/sbe1v1k-full-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-sbe1v1k-full-services $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,sbe1v1k-full-defaults))
