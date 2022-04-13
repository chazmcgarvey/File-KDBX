
# This is not a Perl distribution, but it can build one using Dist::Zilla.

CPANM   = cpanm
COVER   = cover
DZIL    = dzil
PERL    = perl
PROVE   = prove

cpanm_env = AUTHOR_TESTING=0 RELEASE_TESTING=0

all: dist

bootstrap:
	$(cpanm_env) $(CPANM) -nq Dist::Zilla
	$(DZIL) authordeps --missing |$(cpanm_env) $(CPANM) -nq
	$(DZIL) listdeps --develop --missing |$(cpanm_env) $(CPANM) -nq

clean:
	$(DZIL) $@

cover:
	$(COVER) -test

dist:
	$(DZIL) build

test:
	$(PROVE) -l $(if $(V),-vj1)

smoke:
	smoke-all file-kdbx File-KDBX-$V.tar.gz

smokers:
	$(DZIL) listdeps --no-recommends --no-suggests --no-develop --cpanm-versions \
	|$(PERL) -pe 's/"//g' \
	|build-perl-smokers file-kdbx

.PHONY: all bootstrap clean cover dist smoke smokers test
