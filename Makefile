include def.make
include cname.make

export TMPDIR := /tmp

ifneq ($(filter clean,$(MAKECMDGOALS)),clean)

ifndef PYTHON
include .tmp/python_venv.make
endif

CONTAINER_ARCHIVE_FORMAT := oci

ifndef CONTAINER_ENGINE
ifneq ($(shell uname -s),Linux)
USE_PODMAN_MACHINE := 1
endif
include .tmp/container_engine.make
else
ifneq ($(filter Docker,$(shell $(CONTAINER_ENGINE) --version)),)
export DOCKER_BUILDKIT := 0
CONTAINER_ARCHIVE_FORMAT := docker
endif
endif

CONTAINER_RUN_OPTS := --net host --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt label=disable
CONTAINER_RUN := $(CONTAINER_ENGINE) container run $(CONTAINER_RUN_OPTS)

else
ifneq ($(filter-out clean clean_tmp clean_cert,$(MAKECMDGOALS)),)
$(error error: clean cannot be combined with other make targets)
endif
endif

PYTHON_DEPENDENCIES := pyyaml networkx

CONTAINER_BASE_IMAGE := docker.io/debian:bookworm

NATIVE_ARCH := $(shell ./get_arch)
NATIVE_PKGS := bash dash dpkg grep mawk openssh-client policycoreutils sed tar util-linux gzip xz-utils

ifndef CONFIG_DIR
$(error 'CONFIG_DIR undefined')
endif
export CONFIG_DIR

REPO := http://repo.gardenlinux.io/gardenlinux
REPO_KEY := '$(CONFIG_DIR)/keyring.gpg'

DEFAULT_VERSION := $(shell '$(CONFIG_DIR)/get_version')
COMMIT := $(shell CONFIG_DIR='$(CONFIG_DIR)' ./get_commit)

# ————————————————————————————————————————————————————————————————

.PHONY: all_tests all native_tests native none clean clean_tmp container_engine_system_df shellcheck

PLATFORMS := kvm kvm_secureboot kvm_readonly_secureboot metal metal_secureboot metal_readonly_secureboot aws gcp azure ali firecracker

all_tests: $(foreach platform,$(PLATFORMS),test($(platform)-amd64) test($(platform)-arm64))
all: $(foreach platform,$(PLATFORMS),$(platform)-amd64 $(platform)-arm64)
native_tests: $(foreach platform,$(PLATFORMS),test($(platform)-$(NATIVE_ARCH)))
native: $(foreach platform,$(PLATFORMS),test($(platform)-$(NATIVE_ARCH)))

none:

clean: clean_tmp
	rm -rf .build

clean_tmp:
	[ ! -e .tmp/podman ] || podman --cgroup-manager cgroupfs unshare rm -rf .tmp/podman
	if [ -e .tmp/podman_machine ]; then
		machine="$$(cat .tmp/podman_machine)"
		podman machine stop "$$machine" && podman machine rm -f "$$machine" || true
		rm .tmp/podman_machine
	fi
	if [ -L .tmp ]; then
		rm -rf "$$(realpath .tmp)"
		rm .tmp
	elif [ -e .tmp ]; then
		rm -rf .tmp
	fi

container_engine_system_df:
	$(CONTAINER_ENGINE) system df -v

shellcheck:
	git ls-files | while read file; do
		if [ -f "$$file" ] && head -n 1 "$$file" | grep '^#!.*sh$$' &> /dev/null; then
			printf 'checking %s\n' "$$file"
			shellcheck "$$file"
		fi
	done

# ————————————————————————————————————————————————————————————————

.build:
	mkdir .build

.tmp: | .build
	target '$@'
	info 'creating tmp directory'
	if ! fs_type="$$(findmnt -n -o FSTYPE -T "$$TMPDIR" 2> /dev/null)"; then
		echo "warning: checking filesystem type of TMPDIR ($$TMPDIR) failed" >&2
	elif [ "$$fs_type" != tmpfs ]; then
		echo "warning: TMPDIR ($$TMPDIR) is not on a tmpfs, build performance might be reduced" >&2
	fi
	ln -s "$$(mktemp -d -t builder.XXXX)" '$@'
	mkdir .tmp/empty_context
	realpath '$@'
	close_target_log
	rm -f '$@.log'

.tmp/python_venv: | .tmp
	target '$@'
	info 'setting up python venv'
	venv='$@'
	python3 -m venv "$$venv" || (rm -rf "$$venv"; false)
	dependencies='$(PYTHON_DEPENDENCIES)'
	[ -z "$$dependencies" ] || "$$venv/bin/pip" install --no-cache-dir $$dependencies || (rm -rf "$$venv"; false)

.tmp/python_venv.make: | .tmp/python_venv
	target '$@'
	info 'generate $@'
	path="$$(realpath '$|')/bin/python"
	echo "PYTHON := $$path" | tee '$@'

.tmp/podman: | .tmp
	target '$@'
	info 'init podman directory'
	podman_dir='$@'
	mkdir -p "$$podman_dir/"{root,runroot}
	find "$$podman_dir/" -exec realpath '{}' ';'

.tmp/podman_machine: | .tmp
	target '$@'
	info 'initializing podman machine'
	machine="podman-machine-$$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d - | head -c 8)"
	config_path="$$(realpath '$(CONFIG_DIR)')"
	tmp_path="$$(realpath '$|')"
	podman machine init --memory 8192 --disk-size 32 --volume "$$PWD:$$PWD" --volume "$$config_path:$$config_path" --volume "$$tmp_path:$$tmp_path" --now "$$machine"
	podman machine ssh "$$machine" 'echo SELINUX=disabled | sudo tee /etc/selinux/config'
	podman machine stop "$$machine"
	podman machine start "$$machine"
	echo "$$machine" > '$@'

ifndef USE_PODMAN_MACHINE
.tmp/container_engine.make: | .tmp/podman
	target '$@'
	info 'generate $@'
	path="$$(realpath '$|')"
	echo "CONTAINER_ENGINE := podman --root "$$path/root" --runroot "$$path/runroot" --storage-driver vfs --cgroup-manager cgroupfs" | tee '$@'
else
.tmp/container_engine.make: .tmp/podman_machine
	target '$@'
	info 'generate $@'
	machine="$$(cat '$<')"
	echo "IGNORE := \$$(shell ./make_podman_machine_start $$machine)" > '$@'
	echo "CONTAINER_ENGINE := podman --connection '$$machine'" | tee -a '$@'
endif

# ————————————————————————————————————————————————————————————————

.INTERMEDIATE: .tmp/base.image .tmp/debootstrap.image .tmp/e2fsprogs.image

.tmp/base.image:
	target '$@'
	image='$(CONTAINER_BASE_IMAGE)'
	arch='$(NATIVE_ARCH)'
	info "pulling container image $$image"
	$(CONTAINER_ENGINE) image pull --platform "linux/$$arch" "$$image"
	$(CONTAINER_ENGINE) image tag "$$image" "$$image-$$arch"
	echo "$$image-$$arch" > '$@'

.tmp/%.image: %.containerfile .tmp/base.image
	target '$@' '$(lastword $^)'
	info "building $* container"
	containerfile='$(word 1,$^)'
	base_image="$$(cat '$(lastword $^)')"
	$(CONTAINER_ENGINE) image build --file "$$containerfile" --build-arg base="$$base_image" --iidfile '$@' .tmp/empty_context

.tmp/debootstrap.image: .tmp/unshare.image
.tmp/test.image: .tmp/unshare.image

.tmp/%.image: .build/%.tar
	target '$@' '$<'
	info "importing container image $*"
	$(CONTAINER_ENGINE) image import '$<' > '$@'

.build/%.oci: .tmp/%.image
	target '$@' '$<'
	info "saving OCI container image $*"
	image="$$(cat '$<')"
	$(CONTAINER_ENGINE) image save --format oci-archive "$$image" > '$@'

.build/%.docker: .tmp/%.image
	target '$@' '$<'
	info "saving OCI container image $*"
	image="$$(cat '$<')"
	$(CONTAINER_ENGINE) image save "$$image" > '$@'

.tmp/%.container.tar: .tmp/%.container
	target '$@' '$<'
	info "exporting container $*"
	container="$$(cat '$<')"
	$(CONTAINER_ENGINE) container export "$$container" > '$@'
	$(CONTAINER_ENGINE) container rm "$$container" &> /dev/null || true
	rm '$<'

# ————————————————————————————————————————————————————————————————

.build/.repo-%:
	true

.build/bootstrap-%.tar: bootstrap $$(shell ./make_repo_check $$(REPO) $$(call cname_version,$$*)) | .tmp/debootstrap.image
	target '$@'
	info "bootstrapping"
	arch="$$(echo '$*' | cut -d - -f 1)"
	version="$$(echo '$*' | cut -d - -f 2)"
	script_path="$$(realpath '$<')"
	image="$$(cat '$|')"
	touch '$@'
	output_path="$$(realpath '$@')"
	repo_key_path="$$(realpath '$(REPO_KEY)')"
	$(CONTAINER_RUN) --rm "$${repo_key_mount_opts[@]}" -v "$$script_path:/script:ro" -v "$$output_path:/output" -v "$$repo_key_path:/keyring" "$$image" /script "$$arch" "$$version" '$(REPO)' || (rm "$$output_path"; false)

.build/native_bin-%.tar: configure_nativetools .tmp/bootstrap-$(NATIVE_ARCH)-%.image
	target '$@'
	info "configuring native_bin"
	script_path="$$(realpath '$(word 1,$^)')"
	image="$$(cat '$(word 2,$^)')"
	touch '$@'
	output_path="$$(realpath '$@')"
	$(CONTAINER_RUN) --rm -v "$$script_path:/script:ro" -v "$$output_path:/output" "$$image" /script $(NATIVE_PKGS) || (rm "$$output_path"; false)

.tmp/native_bin-%.volume: .build/native_bin-%.tar | .tmp/base.image
	target '$@'
	info "configuring native_bin volume"
	input_path="$$(realpath '$<')"
	image="$$(cat '$|')"
	volume="native_bin-$$(uuidgen | tr '[:upper:]' '[:lower:]')"
	$(CONTAINER_ENGINE) volume create "$$volume"
	$(CONTAINER_RUN) --rm -v "$$input_path:/input:ro" -v "$$volume:/native_bin" "$$image" tar xvf /input || ($(CONTAINER_ENGINE) volume rm "$$volume" &> /dev/null; false)
	echo "$$volume" > '$@'

.tmp/%.container: configure .tmp/bootstrap-$$(call cname_arch,$$*)-$$(call cname_version,$$*).image .tmp/native_bin-$$(call cname_version,$$*).volume $(shell ./make_directory_dependency '$(CONFIG_DIR)/features')
	target '$@' '$(word 2,$^)'
	info "configuring rootfs-$*"
	configure_path="$$(realpath '$(word 1,$^)')"
	image="$$(cat '$(word 2,$^)')"
	volume="$$(cat '$(word 3,$^)')"
	features_dir_path="$$(realpath '$(word 4,$^)')"
	container_env_path="$$($(CONTAINER_RUN) --rm "$$image" bash -c 'echo $$PATH')"
	features="$$($(PYTHON) parse_features --feature-dir '$(CONFIG_DIR)/features' --cname '$*' features)"
	rm -f '$@'
	BUILDER_CNAME='$*'
	BUILDER_VERSION='$(call cname_version,$*)'
	BUILDER_TIMESTAMP="$$($(CONFIG_DIR)/get_timestamp "$$BUILDER_VERSION")"
	BUILDER_COMMIT='$(COMMIT)'
	BUILDER_FEATURES="$$features"
	export BUILDER_CNAME BUILDER_VERSION BUILDER_TIMESTAMP BUILDER_COMMIT BUILDER_FEATURES
	$(CONTAINER_RUN) --cidfile '$@' -v "$$configure_path:/builder/configure:ro" -v "$$volume:/native_bin:ro" -v "$$features_dir_path:/builder/features:ro" -e "PATH=/native_bin:$$container_env_path" -e BUILDER_CNAME -e BUILDER_VERSION -e BUILDER_TIMESTAMP -e BUILDER_COMMIT -e BUILDER_FEATURES "$$image" /builder/configure

.build/%.tar: finalize .tmp/%.container.tar .tmp/native_bin-$$(call cname_version,$$*).volume $(shell ./make_directory_dependency '$(CONFIG_DIR)/features') | .tmp/unshare.image cert
	target '$@' '$(word 2,$^)'
	info "finalizing rootfs $*"
	script_path="$$(realpath '$(word 1,$^)')"
	input_path="$$(realpath '$(word 2,$^)')"
	volume="$$(cat '$(word 3,$^)')"
	features_dir_path="$$(realpath '$(word 4,$^)')"
	image="$$(cat '$(word 1,$|)')"
	touch '$@'
	output_path="$$(realpath '$@')"
	features="$$($(PYTHON) parse_features --feature-dir '$(CONFIG_DIR)/features' --cname '$*' features)"
	BUILDER_CNAME='$*'
	BUILDER_VERSION='$(call cname_version,$*)'
	BUILDER_TIMESTAMP="$$($(CONFIG_DIR)/get_timestamp "$$BUILDER_VERSION")"
	BUILDER_COMMIT='$(COMMIT)'
	BUILDER_FEATURES="$$features"
	export BUILDER_CNAME BUILDER_VERSION BUILDER_TIMESTAMP BUILDER_COMMIT BUILDER_FEATURES
	$(CONTAINER_RUN) --rm -v "$$script_path:/script:ro" -v "$$input_path:/input:ro" -v "$$output_path:/output" -v "$$volume:/native_bin:ro" -v "$$features_dir_path:/builder/features:ro" -e BUILDER_CNAME -e BUILDER_VERSION -e BUILDER_TIMESTAMP -e BUILDER_COMMIT -e BUILDER_FEATURES $(CERT_CONTAINER_OPTS) "$$image" /script || (rm "$$output_path"; false)

.build/%.raw: image .build/%.tar $(shell ./make_directory_dependency image.d) $(shell ./make_directory_dependency '$(CONFIG_DIR)/features') | .tmp/image.image cert
	target '$@' '$(word 2,$^)'
	info "building image $*"
	script_path="$$(realpath '$(word 1,$^)')"
	input_path="$$(realpath '$(word 2,$^)')"
	image_d_path="$$(realpath '$(word 3,$^)')"
	features_dir_path="$$(realpath '$(word 4,$^)')"
	image="$$(cat '$(word 1,$|)')"
	touch '$@'
	output_path="$$(realpath '$@')"
	features="$$($(PYTHON) parse_features --feature-dir '$(CONFIG_DIR)/features' --cname '$*' features)"
	BUILDER_CNAME='$*'
	BUILDER_VERSION='$(call cname_version,$*)'
	BUILDER_TIMESTAMP="$$($(CONFIG_DIR)/get_timestamp "$$BUILDER_VERSION")"
	BUILDER_COMMIT='$(COMMIT)'
	BUILDER_FEATURES="$$features"
	export BUILDER_CNAME BUILDER_VERSION BUILDER_TIMESTAMP BUILDER_COMMIT BUILDER_FEATURES
	$(CONTAINER_RUN) --rm -v "$$script_path:/script:ro" -v "$$input_path:/input:ro" -v "$$output_path:/output" -v "$$image_d_path:/builder/image.d:ro" -v "$$features_dir_path:/builder/features:ro" -e BUILDER_CNAME -e BUILDER_VERSION -e BUILDER_TIMESTAMP -e BUILDER_COMMIT -e BUILDER_FEATURES $(CERT_CONTAINER_OPTS) "$$image" /script || (rm "$$output_path"; false)

# using a more generic .build/% pattern rule won't work here, because make would consider it for the .build/%.artifacts file, thus, despite not using it, marking it as in_use (make-3.75/implicit.c:312) and therefore skipping it in all dependencies to avoid recursion (make-3.75/implicit.c:188)
define artifact_template =
$1: $$$$(shell PYTHON='$$(PYTHON)' CONFIG_DIR='$$(CONFIG_DIR)' ./make_get_image_dependencies '$$$$@') $$(shell ./make_directory_dependency image.d) $$(shell ./make_directory_dependency '$$(CONFIG_DIR)/features') | .tmp/image.image cert
	target '$$@' '$$(word 2,$$^)'
	info "building image $$$$(basename '$$@')"
	script_path="$$$$(realpath '$$(word 1,$$^)')"
	input_path="$$$$(realpath '$$(word 2,$$^)')"
	image_d_path="$$$$(realpath '$$(word 3,$$^)')"
	features_dir_path="$$$$(realpath '$$(word 4,$$^)')"
	image="$$$$(cat '$$(word 1,$$|)')"
	touch '$$@'
	output_path="$$$$(realpath '$$@')"
	artifact='$$*'
	extension="$$$$(grep -E -o '(\.[a-z][a-zA-Z0-9\-_]*)*$$$$' <<< "$$$$artifact")"
	cname="$$$${artifact%"$$$$extension"}"
	features="$$$$($$(PYTHON) parse_features --feature-dir '$$(CONFIG_DIR)/features' --cname "$$$$cname" features)"
	BUILDER_CNAME="$$$$cname"
	BUILDER_VERSION="$$$$($$(PYTHON) parse_features --feature-dir '$$(CONFIG_DIR)/features' --cname "$$$$cname" version)"
	BUILDER_TIMESTAMP="$$$$($$(CONFIG_DIR)/get_timestamp "$$$$BUILDER_VERSION")"
	BUILDER_COMMIT='$$(COMMIT)'
	BUILDER_FEATURES="$$$$features"
	export BUILDER_CNAME BUILDER_VERSION BUILDER_TIMESTAMP BUILDER_COMMIT BUILDER_FEATURES
	$$(CONTAINER_RUN) --rm -v "$$$$script_path:/script:ro" -v "$$$$input_path:/input:ro" -v "$$$$output_path:/output" -v "$$$$image_d_path:/builder/image.d:ro" -v "$$$$features_dir_path:/builder/features:ro" -e BUILDER_CNAME -e BUILDER_VERSION -e BUILDER_TIMESTAMP -e BUILDER_COMMIT -e BUILDER_FEATURES $$(CERT_CONTAINER_OPTS) "$$$$image" /script || (rm "$$$$output_path"; false)
endef

$(foreach artifact_rule,$(shell CONFIG_DIR='$(CONFIG_DIR)' ./make_get_artifact_rules),$(eval $(call artifact_template,$(artifact_rule))))

.build/%.artifacts: $$(shell PYTHON='$(PYTHON)' CONTAINER_ARCHIVE_FORMAT='$(CONTAINER_ARCHIVE_FORMAT)' CONFIG_DIR='$(CONFIG_DIR)' ./make_list_build_artifacts '$$*')
	target '$@'
	echo -n > '$@'
	for f in $^; do
		basename "$$f" | tee -a '$@'
	done

# ————————————————————————————————————————————————————————————————

%: .build/$$(shell $$(PYTHON) parse_features --feature-dir '$$(CONFIG_DIR)/features' --default-arch '$$(NATIVE_ARCH)' --default-version '$$(DEFAULT_VERSION)' --cname '$$*').artifacts
	true

# prevents match anything rule from applying to files in bulid directory
$(shell find . -maxdepth 1 -type f) image.d $(CONFIG_DIR)/features $(CONFIG_DIR)/tests $(shell find $(CONFIG_DIR)/features -name 'convert.*' -o -name 'image.*'):
	true

# ————————————————————————————————————————————————————————————————

test(%): test .build/$$(shell $$(PYTHON) parse_features --feature-dir '$$(CONFIG_DIR)/features' --default-arch '$$(NATIVE_ARCH)' --default-version '$$(DEFAULT_VERSION)' --cname '$$*').tar $(shell ./make_directory_dependency '$(CONFIG_DIR)/features') $(shell ./make_directory_dependency '$(CONFIG_DIR)/tests') | .tmp/test.image
	target '$(patsubst %.tar,%.test,$(word 2,$^))'
	info 'running tests for $*'
	script_path="$$(realpath '$(word 1,$^)')"
	input_path="$$(realpath '$(word 2,$^)')"
	features_dir_path="$$(realpath '$(word 3,$^)')"
	tests_dir_path="$$(realpath '$(word 4,$^)')"
	image="$$(cat '$(word 1,$|)')"
	BUILDER_FEATURES="$$($(PYTHON) parse_features --feature-dir '$(CONFIG_DIR)/features' --cname '$*' features)"
	export BUILDER_FEATURES
	touch "$$tests_dir_path/test.log"
	$(CONTAINER_RUN) --rm -v "$$script_path:/script:ro" -v "$$input_path:/builder/rootfs.tar:ro" -v "$$features_dir_path:/builder/features:ro" -v "$$tests_dir_path:/builder/tests:ro" -e BUILDER_FEATURES "$$image" /script

# ————————————————————————————————————————————————————————————————

ifdef CERT_USE_KMS
CERT_CONTAINER_OPTS := -v '$(realpath cert):/cert' $(shell env | grep '^AWS_' | sed 's/^/-e /')
CERT_MAKE_OPTS := USE_KMS=1

.tmp/aws-kms-pkcs11.image: .tmp/unshare.image
.tmp/cert.image: .tmp/aws-kms-pkcs11.image
.tmp/image.image: .tmp/aws-kms-pkcs11.image
else
CERT_CONTAINER_OPTS := -v '$(realpath cert):/cert'
CERT_MAKE_OPTS :=

.tmp/cert.image: .tmp/unshare.image
.tmp/image.image: .tmp/unshare.image
endif

.PHONY: cert clean_cert

cert: | .tmp/cert.image
	target '$@'
	info "generating certificates"
	image="$$(cat '$|')"
	$(CONTAINER_RUN) --rm $(CERT_CONTAINER_OPTS) "$$image" make --silent -C /cert $(CERT_MAKE_OPTS) default
	rm '$@.log'

clean_cert:
	$(MAKE) --silent -C cert clean
