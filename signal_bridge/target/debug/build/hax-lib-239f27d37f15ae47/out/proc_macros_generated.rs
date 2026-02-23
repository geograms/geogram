
pub use hax_lib_macros::fstar_expr as fstar;
#[doc(hidden)]
pub use hax_lib_macros::fstar_unsafe_expr;
#[doc(hidden)]
pub use hax_lib_macros::fstar_prop_expr;

/// Procedular macros that have an effect only for the backend fstar.
pub mod fstar {
    #[doc(hidden)]
    pub use hax_lib_macros::fstar_unsafe_expr as unsafe_expr;
    pub use hax_lib_macros::fstar_prop_expr as prop;
    pub use hax_lib_macros::fstar_after as after;
    pub use hax_lib_macros::fstar_before as before;
    pub use hax_lib_macros::fstar_replace as replace;
    pub use hax_lib_macros::fstar_replace_body as replace_body;

    
pub use hax_lib_macros::fstar_options as options;
pub use hax_lib_macros::fstar_verification_status as verification_status;
pub use hax_lib_macros::fstar_smt_pat as smt_pat;
pub use hax_lib_macros::fstar_postprocess_with as postprocess_with;

}


pub use hax_lib_macros::proverif_expr as proverif;
#[doc(hidden)]
pub use hax_lib_macros::proverif_unsafe_expr;
#[doc(hidden)]
pub use hax_lib_macros::proverif_prop_expr;

/// Procedular macros that have an effect only for the backend proverif.
pub mod proverif {
    #[doc(hidden)]
    pub use hax_lib_macros::proverif_unsafe_expr as unsafe_expr;
    pub use hax_lib_macros::proverif_prop_expr as prop;
    pub use hax_lib_macros::proverif_after as after;
    pub use hax_lib_macros::proverif_before as before;
    pub use hax_lib_macros::proverif_replace as replace;
    pub use hax_lib_macros::proverif_replace_body as replace_body;

    
}


pub use hax_lib_macros::coq_expr as coq;
#[doc(hidden)]
pub use hax_lib_macros::coq_unsafe_expr;
#[doc(hidden)]
pub use hax_lib_macros::coq_prop_expr;

/// Procedular macros that have an effect only for the backend coq.
pub mod coq {
    #[doc(hidden)]
    pub use hax_lib_macros::coq_unsafe_expr as unsafe_expr;
    pub use hax_lib_macros::coq_prop_expr as prop;
    pub use hax_lib_macros::coq_after as after;
    pub use hax_lib_macros::coq_before as before;
    pub use hax_lib_macros::coq_replace as replace;
    pub use hax_lib_macros::coq_replace_body as replace_body;

    
}


pub use hax_lib_macros::lean_expr as lean;
#[doc(hidden)]
pub use hax_lib_macros::lean_unsafe_expr;
#[doc(hidden)]
pub use hax_lib_macros::lean_prop_expr;

/// Procedular macros that have an effect only for the backend lean.
pub mod lean {
    #[doc(hidden)]
    pub use hax_lib_macros::lean_unsafe_expr as unsafe_expr;
    pub use hax_lib_macros::lean_prop_expr as prop;
    pub use hax_lib_macros::lean_after as after;
    pub use hax_lib_macros::lean_before as before;
    pub use hax_lib_macros::lean_replace as replace;
    pub use hax_lib_macros::lean_replace_body as replace_body;

    
}
