lastword = $(word $(words $1),$1)
prelastword = $(word $(words $1),_ $1)
cname_version = $(call lastword,$(subst -, ,$1))
cname_arch = $(call prelastword,$(subst -, ,$1))
