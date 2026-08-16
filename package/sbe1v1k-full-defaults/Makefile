include $(TOPDIR)/rules.mk

PKG_NAME:=sbe1v1k-full-defaults
PKG_VERSION:=1.0
SBE_BUILD_GIT_COMMIT:=$(shell git -C $(TOPDIR) rev-parse HEAD 2>/dev/null || echo unknown)
SBE_BUILD_GIT_DESCRIBE:=$(shell git -C $(TOPDIR) describe --always --dirty 2>/dev/null || echo unknown)
SBE_BUILD_GIT_DIRTY:=$(shell git -C $(TOPDIR) diff-index --quiet HEAD -- 2>/dev/null && test -z "$$(git -C $(TOPDIR) ls-files --others --exclude-standard 2>/dev/null)" && echo no || echo yes)

PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe1v1k-full-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Safe service defaults for the SBE1V1K full image
  DEPENDS:=+apk
endef

define Package/sbe1v1k-full-defaults/description
  Keeps optional server components disabled until the administrator explicitly
  configures and enables them. Also configures the signed PassWall binary
  repositories recommended by the upstream PassWall project.
endef

define Build/Compile
endef

define Package/sbe1v1k-full-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/zz-sbe1v1k-fw4-migrate $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/99-sbe1v1k-full-services $(1)/etc/uci-defaults/
	$(INSTALL_DIR) $(1)/etc/apk/keys
	$(INSTALL_DATA) ./files/openwrt-passwall-build.pem $(1)/etc/apk/keys/
	$(INSTALL_DIR) $(1)/etc/apk/repositories.d
	$(INSTALL_DATA) ./files/passwall.list $(1)/etc/apk/repositories.d/
	$(SED) 's,@ARCH_PACKAGES@,$(ARCH_PACKAGES),g' \
		$(1)/etc/apk/repositories.d/passwall.list
	$(INSTALL_DIR) $(1)/etc
	( \
		echo 'git_commit=$(SBE_BUILD_GIT_COMMIT)'; \
		echo 'git_describe=$(SBE_BUILD_GIT_DESCRIBE)'; \
		echo 'git_dirty=$(SBE_BUILD_GIT_DIRTY)'; \
		echo 'source_date_epoch=$(SOURCE_DATE_EPOCH)'; \
	) > $(1)/etc/sbe1v1k-build-info
endef

$(eval $(call BuildPackage,sbe1v1k-full-defaults))
