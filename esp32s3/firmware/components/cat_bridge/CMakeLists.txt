idf_component_register(
    SRCS "ring_buf.c" "coalescer.c" "radio_detect.c" "bridge_core.c"
    INCLUDE_DIRS "include"
    REQUIRES ctrl_proto
)
