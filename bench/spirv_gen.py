#!/usr/bin/env python3
# Hand-assembles minimal SPIR-V for a vertex shader (NDC triangle from
# gl_VertexIndex) and a fragment shader (constant orange), no toolchain needed.
import struct, sys

def ins(op, *ops):
    return struct.pack("<I", (1 + len(ops)) << 16 | op) + b"".join(struct.pack("<I", o) for o in ops)

def header(bound):
    return struct.pack("<IIIII", 0x07230203, 0x00010000, 0, bound, 0)

CAP, MEM, ENTRY, EXEMODE, DECORATE = 17, 14, 15, 16, 71
TVOID, TBOOL, TINT, TFLOAT, TVEC, TFN, TPTR = 19, 20, 21, 22, 23, 33, 32
CONST, CONSTCOMP, VAR, FN, LABEL, STORE, RET, FNEND = 43, 44, 59, 54, 248, 62, 253, 56
LOAD, IEQ, SELECT, COMPOSITE = 61, 170, 169, 80
NAME_MAIN = (0x6e69616d, 0x00000000)

def vertex_shader():
    # ids: 1=main 2=glpos 3=vi 4=void 5=fn 6=float 7=vec4 8=ptrOutVec4
    #      9=int 10=ptrInInt 11=bool 12=-0.5 13=0.5 14=0.0 15=1.0
    #      16=int0 17=int1 18=int2 19=vloaded 20=eq1 21=eq0 22=selx0 23=x
    #      24=eq2 25=y 26=vec 27=label
    b = b"".join([
        ins(CAP, 1),                     # OpCapability Shader
        ins(MEM, 0, 1),                  # Logical GLSL450
        ins(ENTRY, 0, 1, *NAME_MAIN, 2, 3),  # Vertex, main, iface glpos+vi
        ins(DECORATE, 2, 11, 0),         # glpos BuiltIn Position
        ins(DECORATE, 3, 11, 42),        # vi BuiltIn VertexIndex
        ins(TVOID, 4),
        ins(TFN, 5, 4),
        ins(TFLOAT, 6, 32),
        ins(TVEC, 7, 6, 4),
        ins(TPTR, 8, 3, 7),              # ptr Output vec4
        ins(TINT, 9, 32, 1),             # int32
        ins(TPTR, 10, 1, 9),             # ptr Input int
        ins(TBOOL, 11),
        ins(CONST, 6, 12, 0xBF000000),   # -0.5f
        ins(CONST, 6, 13, 0x3F000000),   #  0.5f
        ins(CONST, 6, 14, 0x00000000),   #  0.0f
        ins(CONST, 6, 15, 0x3F800000),   #  1.0f
        ins(CONST, 9, 16, 0),
        ins(CONST, 9, 17, 1),
        ins(CONST, 9, 18, 2),
        ins(VAR, 8, 2, 3),               # glpos : Output vec4
        ins(VAR, 10, 3, 1),              # vi : Input int
        ins(FN, 4, 1, 0, 5),             # main()
        ins(LABEL, 27),
        ins(LOAD, 9, 19, 3),             # %19 = load vi
        ins(IEQ, 11, 20, 19, 17),        # vi == 1
        ins(IEQ, 11, 21, 19, 16),        # vi == 0
        ins(SELECT, 6, 22, 21, 12, 14),  # x0 = (vi==0) ? -0.5 : 0.0
        ins(SELECT, 6, 23, 20, 13, 22),  # x  = (vi==1) ?  0.5 : x0
        ins(IEQ, 11, 24, 19, 18),        # vi == 2
        ins(SELECT, 6, 25, 24, 13, 12),  # y  = (vi==2) ?  0.5 : -0.5
        ins(COMPOSITE, 7, 26, 23, 25, 14, 15),  # vec4(x, y, 0, 1)
        ins(STORE, 2, 26),               # gl_Position = ...
        ins(RET),
        ins(FNEND),
    ])
    return header(28) + b

def fragment_shader():
    # ids: 1=main 2=color 3=void 4=fn 5=float 6=vec4 7=ptrOutVec4
    #      8=1.0 9=0.5 10=0.0 11=composite 12=label
    b = b"".join([
        ins(CAP, 1),
        ins(MEM, 0, 1),
        ins(ENTRY, 4, 1, *NAME_MAIN, 2),     # Fragment, main, iface color
        ins(EXEMODE, 1, 7),                  # OriginUpperLeft
        ins(DECORATE, 2, 30, 0),             # color Location 0
        ins(TVOID, 3),
        ins(TFN, 4, 3),
        ins(TFLOAT, 5, 32),
        ins(TVEC, 6, 5, 4),
        ins(TPTR, 7, 3, 6),              # ptr Output vec4
        ins(CONST, 5, 8, 0x3F800000),    # 1.0f
        ins(CONST, 5, 9, 0x3F000000),    # 0.5f
        ins(CONST, 5, 10, 0),            # 0.0f
        ins(CONSTCOMP, 6, 11, 8, 9, 10, 8),  # vec4(1, .5, 0, 1) = orange
        ins(VAR, 7, 2, 3),               # color : Output vec4
        ins(FN, 3, 1, 0, 4),
        ins(LABEL, 12),
        ins(STORE, 2, 11),
        ins(RET),
        ins(FNEND),
    ])
    return header(13) + b

open(sys.argv[1], "wb").write(vertex_shader())
open(sys.argv[2], "wb").write(fragment_shader())
print("wrote", sys.argv[1], "and", sys.argv[2])
