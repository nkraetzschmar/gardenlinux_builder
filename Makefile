include def.make

export TMPDIR := /tmp

ifneq ($(filter clean,$(MAKECMDGOALS)),clean)

ifndef PYTHON
include .tmp/python_venv.make
endif

ARCHIVE_FORMAT := oci

ifndef CONTAINER_ENGINE
ifneq ($(shell uname -s),Linux)
USE_PODMAN_MACHINE := 1
endif
include .tmp/container_engine.make
else
ifneq ($(filter Docker,$(shell $(CONTAINER_ENGINE) --version)),)
export DOCKER_BUILDKIT := 0
ARCHIVE_FORMAT := docker
endif
endif

CONTAINER_RUN_OPTS := --net host --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt label=disable
CONTAINER_RUN := $(CONTAINER_ENGINE) container run $(CONTAINER_RUN_OPTS)

else
ifneq ($(MAKECMDGOALS),clean)
$(error error: clean cannot be combined with other make targets)
endif
endif

PYTHON_DEPENDENCIES := pyyaml networkx

ifndef REPO
REPO := http://repo.gardenlinux.io/gardenlinux
REPO_KEY := gardenlinux.asc
DEFAULT_VERSION := today
else
DEFAULT_VERSION := bookworm
endif

CONTAINER_BASE_IMAGE := docker.io/debian:bookworm

NATIVE_ARCH := $(shell ./arch_mapping)
NATIVE_PKGS := bash dash dpkg policycoreutils tar gzip xz-utils

# ————————————————————————————————————————————————————————————————

.PHONY: all all_bootstrap native native_bootstrap none clean clean_tmp container_engine_system_df

all: .build/rootfs-amd64-$(DEFAULT_VERSION).ext4 .build/rootfs-arm64-$(DEFAULT_VERSION).ext4 .build/rootfs-amd64-$(DEFAULT_VERSION).$(ARCHIVE_FORMAT) .build/rootfs-arm64-$(DEFAULT_VERSION).$(ARCHIVE_FORMAT)
all_bootstrap: .build/bootstrap-amd64-$(DEFAULT_VERSION).tar .build/bootstrap-arm64-$(DEFAULT_VERSION).tar .build/native_bin-$(DEFAULT_VERSION).tar

native: .build/rootfs-$(NATIVE_ARCH)-$(DEFAULT_VERSION).ext4 .build/rootfs-$(NATIVE_ARCH)-$(DEFAULT_VERSION).$(ARCHIVE_FORMAT)
native_bootstrap: .build/bootstrap-$(NATIVE_ARCH)-$(DEFAULT_VERSION).tar .build/native_bin-$(DEFAULT_VERSION).tar

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
	path="$$(realpath '$|')"
	podman machine init --disk-size 32 --volume "$$PWD:$$PWD" --volume "$$path:$$path" --now "$$machine"
	podman machine ssh "$$machine" 'sudo rpm-ostree install qemu-user-static && echo SELINUX=disabled | sudo tee /etc/selinux/config && sudo sync'
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

.INTERMEDIATE: .tmp/base.image

.tmp/base.image:
	target '$@'
	image='$(CONTAINER_BASE_IMAGE)'
	arch='$(NATIVE_ARCH)'
	info "pulling container image $$image"
	$(CONTAINER_ENGINE) image pull --platform "linux/$$arch" "$$image"
	$(CONTAINER_ENGINE) image tag "$$image" "$$image-$$arch"
	echo "$$image-$$arch" > '$@'

.tmp/%.image: %.containerfile .tmp/base.image
	target '$@' '$(word 2,$^)'
	info "building $* container"
	containerfile='$(word 1,$^)'
	base_image="$$(cat '$(word 2,$^)')"
	$(CONTAINER_ENGINE) image build --file "$$containerfile" --build-arg base="$$base_image" --iidfile '$@' .

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
	$(CONTAINER_ENGINE) container rm "$$container"
	rm '$<'

# ————————————————————————————————————————————————————————————————

.PRECIOUS: .build/.repo-% .build/bootstrap-%.tar .build/native_bin-%.tar .build/rootfs-%.tar .build/rootfs-%.ext4 .build/%.oci

.build/.repo-%:
	true

.build/bootstrap-%.tar: bootstrap $$(shell ./make_repo_check $$(REPO) $$*) | .tmp/debootstrap.image
	target '$@'
	info "bootstrapping"
	arch="$$(echo '$*' | cut -d - -f 1)"
	version="$$(echo '$*' | cut -d - -f 2)"
	script_path="$$(realpath '$<')"
	image="$$(cat '$|')"
	output_path="$$(realpath '$@')"
	touch "$$output_path"
	repo_key_args=()
	repo_key_mount_opts=()
	if [ -n '$(REPO_KEY)' ]; then
		repo_key_name="$$(basename '$(REPO_KEY)')"
		repo_key_args+=("/$$repo_key_name")
		repo_key_mount_opts+=(-v "$$(realpath '$(REPO_KEY)'):/$$repo_key_name")
	fi
	$(CONTAINER_RUN) --rm "$${repo_key_mount_opts[@]}" -v "$$script_path:/script:ro" -v "$$output_path:/output" "$$image" /script "$$arch" "$$version" '$(REPO)' "$${repo_key_args[@]}" || (rm "$$output_path"; false)

.build/native_bin-%.tar: configure_nativetools .tmp/bootstrap-$(NATIVE_ARCH)-%.image
	target '$@'
	info "configuring native_bin"
	script_path="$$(realpath '$(word 1,$^)')"
	image="$$(cat '$(word 2,$^)')"
	output_path="$$(realpath '$@')"
	touch "$$output_path"
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

.tmp/rootfs-%.container: configure .tmp/native_bin-$$(word 2,$$(subst -, ,$$*)).volume | .tmp/bootstrap-%.image
	target '$@' '$(word 2,$^)'
	info "configuring rootfs-$*"
	configure_path="$$(realpath '$(word 1,$^)')"
	volume="$$(cat '$(word 2,$^)')"
	image="$$(cat '$|')"
	container_env_path="$$($(CONTAINER_RUN) --rm "$$image" bash -c 'echo $$PATH')"
	rm -f '$@'
	$(CONTAINER_RUN) --cidfile '$@' -v "$$configure_path:/builder/configure:ro" -v "$$volume:/native_bin:ro" -e "PATH=/native_bin:$$PATH" "$$image" /builder/configure

.build/rootfs-%.tar: finalize .tmp/rootfs-%.container.tar .tmp/native_bin-$$(word 2,$$(subst -, ,$$*)).volume | .tmp/unshare.image
	target '$@' '$(word 2,$^)'
	info "finalizing rootfs-$*"
	script_path="$$(realpath '$(word 1,$^)')"
	input_path="$$(realpath '$(word 2,$^)')"
	volume="$$(cat '$(word 3,$^)')"
	image="$$(cat '$|')"
	output_path="$$(realpath '$@')"
	touch "$$output_path"
	$(CONTAINER_RUN) --rm -v "$$script_path:/script:ro" -v "$$input_path:/input:ro" -v "$$output_path:/output" -v "$$volume:/native_bin:ro" "$$image" /script || (rm "$$output_path"; false)

.build/rootfs-%.ext4: image .build/rootfs-%.tar | .tmp/e2fsprogs.image
	target '$@' '$(word 2,$^)'
	info "finalizing rootfs-$*"
	script_path="$$(realpath '$(word 1,$^)')"
	input_path="$$(realpath '$(word 2,$^)')"
	image="$$(cat '$|')"
	output_path="$$(realpath '$@')"
	touch "$$output_path"
	$(CONTAINER_RUN) --rm -v "$$script_path:/script:ro" -v "$$input_path:/input:ro" -v "$$output_path:/output" "$$image" /script || (rm "$$output_path"; false)
