//! Adapters for the command-line tools in the CUDA toolkit.

mod fatbinary;
mod frontend;
mod nvcc;
mod nvlink;
mod nvprune;
mod ptxas;

pub use fatbinary::fatbinary;
pub use frontend::frontend;
pub use nvcc::nvcc;
pub use nvlink::nvlink;
pub use nvprune::nvprune;
pub use ptxas::ptxas;
