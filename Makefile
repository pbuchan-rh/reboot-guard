# Optional RPM build. The plain files in files/ and bin/ stay the product; the RPM is built from them.
# make tarball : git archive of HEAD (committed content only) -> rpm/reboot-guard-VERSION.tar.gz
# make check : the helper writes the same drop-ins as files/ (tests/drift.sh), image-mode install refuses (tests/image.sh; REBOOT_GUARD_ROOT=dir = install into dir, test only)
# make srpm / make rpm : rpmbuild in ~/rpmbuild (needs rpm-build); RELEASE=2 bumps the release.
#   BUILDHOST=name sets the RPM's Build Host (default localhost: no build machine hostname in the header);
#   RPMBUILD_FLAGS='...' adds rpmbuild options.
# make sums : TOPDIR/SHA256SUMS for the RPM, SRPM and tarball (file names only: sha256sum -c in a download dir).
NAME    := reboot-guard
SPEC    := rpm/$(NAME).spec
VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' $(SPEC))
RELEASE ?= 1
TARBALL := rpm/$(NAME)-$(VERSION).tar.gz
TOPDIR  ?= $(HOME)/rpmbuild
BUILDHOST ?= localhost
RPMBUILD_FLAGS ?=
RPM     := $(TOPDIR)/RPMS/noarch/$(NAME)-$(VERSION)-$(RELEASE).noarch.rpm
SRPM    := $(TOPDIR)/SRPMS/$(NAME)-$(VERSION)-$(RELEASE).src.rpm
SUMS    := $(TOPDIR)/SHA256SUMS

.PHONY: check tarball srpm rpm sums clean
check:
	tests/drift.sh && tests/image.sh

tarball:
	git archive --format=tar.gz --prefix=$(NAME)-$(VERSION)/ -o $(TARBALL) HEAD

srpm: tarball
	mkdir -p $(TOPDIR)/SOURCES $(TOPDIR)/SPECS
	cp $(TARBALL) $(TOPDIR)/SOURCES/
	cp $(SPEC) $(TOPDIR)/SPECS/
	rpmbuild --define '_topdir $(TOPDIR)' --define 'rel $(RELEASE)' --define '_buildhost $(BUILDHOST)' $(RPMBUILD_FLAGS) -bs $(TOPDIR)/SPECS/$(NAME).spec

rpm: tarball
	mkdir -p $(TOPDIR)/SOURCES $(TOPDIR)/SPECS
	cp $(TARBALL) $(TOPDIR)/SOURCES/
	cp $(SPEC) $(TOPDIR)/SPECS/
	rpmbuild --define '_topdir $(TOPDIR)' --define 'rel $(RELEASE)' --define '_buildhost $(BUILDHOST)' $(RPMBUILD_FLAGS) -ba $(TOPDIR)/SPECS/$(NAME).spec
	@printf '%s\n' $(RPM) $(SRPM) $(TARBALL)

sums:
	@for f in $(RPM) $(SRPM) $(TARBALL); do [ -f $$f ] || { echo "missing $$f (make rpm first)" >&2; exit 1; }; done
	for f in $(RPM) $(SRPM) $(TARBALL); do (cd "$$(dirname $$f)" && sha256sum "$$(basename $$f)") || exit 1; done > $(SUMS)
	@echo $(SUMS)

clean:
	rm -f rpm/*.tar.gz
