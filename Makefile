# -----------------------------------------------------------------------------
# $Id: Makefile,v 1.1 2002/02/24 17:18:03 panne Exp $

TOP=..
include $(TOP)/mk/boilerplate.mk

# -----------------------------------------------------------------------------

ALL_DIRS = \
	Graphics/Drawing \
	Graphics/Drawing/OpenGL \
	Graphics/Drawing/OpenGL/GL \
	Graphics/Drawing/OpenGL/GLU

PACKAGE = OpenGL

SRC_HC_OPTS += -fglasgow-exts '-\#include <GL/glu.h>'

# yeuch, have to get GL_CFLAGS & GL_LIBS in through CPP to OpenGL.conf.in
comma = ,
PACKAGE_CPP_OPTS += -DGL_CFLAGS='$(patsubst %,$(comma)"%",$(GL_CFLAGS))'
PACKAGE_CPP_OPTS += -DGL_LIBS='$(patsubst %,$(comma)"%",$(GL_LIBS))'

# -----------------------------------------------------------------------------
# Per-module flags

# -----------------------------------------------------------------------------

include $(TOP)/mk/target.mk
