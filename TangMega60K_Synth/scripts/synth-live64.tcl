# Execute from project root; no invented board pins or timing exceptions.
open_project Live64_Diagnostic.gprj
set_option -top_module live64_system_top
run syn
