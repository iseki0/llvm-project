// RUN: mlir-opt --transform-interpreter --scf-for-loop-canonicalization --canonicalize --split-input-file %s | FileCheck %s
// RUN: mlir-opt --transform-interpreter --split-input-file %s | FileCheck %s --check-prefix=NOCANON

// This implements a 2D multisize tiling with target sizes [3, 10].
module attributes {transform.with_named_sequence} {
  transform.named_sequence @__transform_main(%arg1: !transform.any_op {transform.readonly}) {
    %0 = transform.structured.match ops{["linalg.generic"]} in %arg1 : (!transform.any_op) -> !transform.any_op
    %1:3 = transform.structured.multitile_sizes %0 { dimension = 0, target_size = 3} : (!transform.any_op) -> !transform.any_op
    %split = transform.structured.split %0 after %1#2 { dimension = 0 } : !transform.any_op, !transform.any_op
    %2:2 = transform.split_handle %split : (!transform.any_op) -> (!transform.any_op, !transform.any_op)
    %3:2 = transform.structured.tile_using_for %2#0 tile_sizes [%1#0] : (!transform.any_op, !transform.any_op) -> (!transform.any_op, !transform.any_op)
    %4:2 = transform.structured.tile_using_for %2#1 tile_sizes [%1#1] : (!transform.any_op, !transform.any_op) -> (!transform.any_op, !transform.any_op)
    %5 = transform.merge_handles %3#0, %4#0 : !transform.any_op
    transform.foreach %5 : !transform.any_op {
    ^bb0(%inner_linalg: !transform.any_op):
      %low, %high, %split_point = transform.structured.multitile_sizes %inner_linalg { dimension = 1, target_size = 10} : (!transform.any_op) -> !transform.any_op
      %split2 = transform.structured.split %inner_linalg after %split_point { dimension = 1 } : !transform.any_op, !transform.any_op
      %inner_linalg_low, %inner_linalg_high = transform.split_handle %split2 : (!transform.any_op) -> (!transform.any_op, !transform.any_op)
      transform.structured.tile_using_for %inner_linalg_low tile_sizes [0, %low] : (!transform.any_op, !transform.any_op) -> (!transform.any_op, !transform.any_op)
      transform.structured.tile_using_for %inner_linalg_high tile_sizes [0, %high] : (!transform.any_op, !transform.any_op) -> (!transform.any_op, !transform.any_op)
    }
    transform.yield
  }
}

func.func private @elem(%arg0: f32, %arg1: index, %arg2: index) -> f32

// Without canonicalization, tile sizes are computed dynamically as affine maps.
// NOCANON-LABEL: @two_d
// NOCANON-COUNT-8: affine.apply
// NOCANON:         scf.for

// CHECK-LABEL: @two_d
// CHECK-SAME: %[[IN:.+]]: tensor<10x34xf32>, %[[OUT:.+]]: tensor<10x34xf32>
func.func @two_d(%arg0: tensor<10x34xf32>,
                 %arg1: tensor<10x34xf32>) -> tensor<10x34xf32> {
  %0 = linalg.generic {
    indexing_maps = [affine_map<(i, j) -> (i, j)>,
                     affine_map<(i, j) -> (i, j)>],
    iterator_types = ["parallel", "parallel"]
  }
  ins(%arg0: tensor<10x34xf32>)
  outs(%arg1: tensor<10x34xf32>) {
  ^bb0(%0: f32, %1: f32):
    %i = linalg.index 0 : index
    %j = linalg.index 1 : index
    %call_res = func.call @elem(%0, %i, %j) : (f32, index, index) -> f32
    linalg.yield %call_res : f32
  } -> tensor<10x34xf32>

  // 2D multi-size tiling should produce for quadrants with sizes
  //   (2, 8), (2, 9), (3, 8), (3, 9)
  // respectively, and in this order.
  // Check the full code for the first quadrant, the data flow for the second
  // quadrant and only the overall code structure for the remaining quadrants.
  // The canonicalizer is able to recover static shapes of for linalg.generic
  // instances, use those to differentiate the quadrants.

  // CHECK:      %[[SLICE_1_IN:.+]] = tensor.extract_slice %[[IN]][0, 0] [4, 34] [1, 1]
  // CHECK:      %[[SLICE_1:.+]] = tensor.extract_slice %[[OUT]][0, 0] [4, 34] [1, 1]
  // CHECK:      scf.for %[[I1:.+]] = %{{.*}} to %{{.*}} step %{{.*}} iter_args(%[[ITERARG_1:.+]] = %[[SLICE_1]])
  // CHECK:        %[[OUTSLICE_1_IN:.+]] = tensor.extract_slice %[[SLICE_1_IN]][%[[I1]], 0] [2, 34] [1, 1]
  // CHECK:        %[[OUTSLICE_1:.+]] = tensor.extract_slice %[[ITERARG_1]][%[[I1]], 0] [2, 34] [1, 1]

  // CHECK:        %[[SLICE_2_IN:.+]] = tensor.extract_slice %[[OUTSLICE_1_IN]][0, 0] [2, 16] [1, 1]
  // CHECK:        %[[SLICE_2:.+]] = tensor.extract_slice %[[OUTSLICE_1]][0, 0] [2, 16] [1, 1]
  // CHECK:        %[[LOOPRES:.+]] = scf.for %[[I2:.+]] = %{{.*}} to %{{.*}} step %{{.*}} iter_args(%[[ITERARG_2:.+]] = %[[SLICE_2]])
  // CHECK:          %[[INSLICE_2:.+]] = tensor.extract_slice %[[SLICE_2_IN]][0, %[[I2]]] [2, 8] [1, 1]
  // CHECK:          %[[OUTSLICE_2:.+]] = tensor.extract_slice %[[ITERARG_2]][0, %[[I2]]] [2, 8] [1, 1]
  // CHECK:          %[[RESSLICE_1:.+]] = linalg.generic {{.*}} ins(%[[INSLICE_2]] : tensor<2x8xf32>) outs(%[[OUTSLICE_2]] : tensor<2x8xf32>)
  // CHECK:          %[[RESPARTIAL:.+]] = tensor.insert_slice %[[RESSLICE_1]] into %[[ITERARG_2]]
  // CHECK:          scf.yield %[[RESPARTIAL]]

  // CHECK:        %[[INSERTED:.+]] = tensor.insert_slice %[[LOOPRES]] into %[[OUTSLICE_1]][0, 0] [2, 16] [1, 1]
  // CHECK:        %[[OUTSLICE_3:.+]] = tensor.extract_slice %[[INSERTED]][0, 16] [2, 18] [1, 1]
  // CHECK:        scf.for %{{.*}} iter_args(%{{.*}} = %[[OUTSLICE_3]])
  // CHECK-COUNT-2:  tensor.extract_slice
  // CHECK:          linalg.generic {{.*}} ins(%{{.*}} : tensor<2x9xf32>)
  // CHECK:          tensor.insert_slice
  // CHECK:          scf.yield
  // CHECK:        %[[INSERTED_2:.+]] = tensor.insert_slice %{{.*}} into %[[INSERTED]]
  // CHECK:        %[[INSERTED_3:.+]] = tensor.insert_slice %[[INSERTED_2]] into %[[ITERARG_1]]
  // CHECK:        scf.yield %[[INSERTED_3]]

  // CHECK:        tensor.insert_slice
  // CHECK:        tensor.extract_slice
  // CHECK:        scf.for
  // CHECK-COUNT-2:  tensor.extract_slice
  // CHECK:          scf.for
  // CHECK-COUNT-2:    tensor.extract_slice
  // CHECK:            linalg.generic {{.*}} ins(%{{.*}} : tensor<3x8xf32>)
  // CHECK:            tensor.insert_slice
  // CHECK:            scf.yield
  // CHECK:          tensor.insert_slice
  // CHECK:          tensor.extract_slice
  // CHECK:          scf.for
  // CHECK-COUNT-2:    tensor.extract_slice
  // CHECK:            linalg.generic {{.*}} ins(%{{.*}} : tensor<3x9xf32>)
  // CHECK:            tensor.insert_slice
  // CHECK:            scf.yield
  // CHECK-COUNT-2:  tensor.insert_slice
  // CHECK:          scf.yield
  // CHECK:        %[[RESULT:.+]] = tensor.insert_slice
  // CHECK:        return %[[RESULT]]

  return %0 : tensor<10x34xf32>
}

// -----

module attributes {transform.with_named_sequence} {
  transform.named_sequence @__transform_main(%arg1: !transform.any_op {transform.readonly}) {
    %0 = transform.structured.match ops{["linalg.generic"]} in %arg1 : (!transform.any_op) -> !transform.any_op
    %1:3 = transform.structured.multitile_sizes %0 { dimension = 0, target_size = 3} : (!transform.any_op) -> !transform.param<i64>
    %t:3 = transform.structured.multitile_sizes %0 { dimension = 1, target_size = 10} : (!transform.any_op) -> !transform.param<i64>
    %split = transform.structured.split %0 after %1#2 { dimension = 0 } : !transform.any_op, !transform.param<i64>
    %2:2 = transform.split_handle %split : (!transform.any_op) -> (!transform.any_op, !transform.any_op)
    %3:2 = transform.structured.tile_using_for %2#0 tile_sizes [%1#0] : (!transform.any_op, !transform.param<i64>) -> (!transform.any_op, !transform.any_op)
    %4:2 = transform.structured.tile_using_for %2#1 tile_sizes [%1#1] : (!transform.any_op, !transform.param<i64>) -> (!transform.any_op, !transform.any_op)
    %5 = transform.merge_handles %3#0, %4#0 : !transform.any_op
    %tt:3 = transform.replicate num(%5) %t#0, %t#1, %t#2 : !transform.any_op, !transform.param<i64>, !transform.param<i64>, !transform.param<i64>
    transform.foreach %5, %tt#0, %tt#1, %tt#2 : !transform.any_op, !transform.param<i64>, !transform.param<i64>, !transform.param<i64> {
    ^bb0(%inner_linalg: !transform.any_op, %low: !transform.param<i64>, %high: !transform.param<i64>, %split_point: !transform.param<i64>):
      %split2 = transform.structured.split %inner_linalg after %split_point { dimension = 1 } : !transform.any_op, !transform.param<i64>
      %inner_linalg_low, %inner_linalg_high = transform.split_handle %split2 : (!transform.any_op) -> (!transform.any_op, !transform.any_op)
      transform.structured.tile_using_for %inner_linalg_low tile_sizes [0, %low] : (!transform.any_op, !transform.param<i64>) -> (!transform.any_op, !transform.any_op)
      transform.structured.tile_using_for %inner_linalg_high tile_sizes [0, %high] : (!transform.any_op, !transform.param<i64>) -> (!transform.any_op, !transform.any_op)
    }
    transform.yield
  }
}

func.func private @elem(%arg0: f32, %arg1: index, %arg2: index) -> f32

// Even without canonicalization, tile sizes can be computed statically thanks
// to parameters.
// NOCANON-LABEL: @two_d
// NOCANON-NOT:   affine.apply
// NOCANON:       scf.for

// CHECK-LABEL: @two_d_param
// CHECK-SAME: %[[IN:.+]]: tensor<10x34xf32>, %[[OUT:.+]]: tensor<10x34xf32>
func.func @two_d_param(%arg0: tensor<10x34xf32>,
                       %arg1: tensor<10x34xf32>) -> tensor<10x34xf32> {
  %0 = linalg.generic {
    indexing_maps = [affine_map<(i, j) -> (i, j)>,
                     affine_map<(i, j) -> (i, j)>],
    iterator_types = ["parallel", "parallel"]
  }
  ins(%arg0: tensor<10x34xf32>)
  outs(%arg1: tensor<10x34xf32>) {
  ^bb0(%0: f32, %1: f32):
    %i = linalg.index 0 : index
    %j = linalg.index 1 : index
    %call_res = func.call @elem(%0, %i, %j) : (f32, index, index) -> f32
    linalg.yield %call_res : f32
  } -> tensor<10x34xf32>

  // CHECK:      %[[SLICE_1_IN:.+]] = tensor.extract_slice %[[IN]][0, 0] [4, 34] [1, 1]
  // CHECK:      %[[SLICE_1:.+]] = tensor.extract_slice %[[OUT]][0, 0] [4, 34] [1, 1]
  // CHECK:      scf.for %[[I1:.+]] = %{{.*}} to %{{.*}} step %{{.*}} iter_args(%[[ITERARG_1:.+]] = %[[SLICE_1]])
  // CHECK:        %[[OUTSLICE_1_IN:.+]] = tensor.extract_slice %[[SLICE_1_IN]][%[[I1]], 0] [2, 34] [1, 1]
  // CHECK:        %[[OUTSLICE_1:.+]] = tensor.extract_slice %[[ITERARG_1]][%[[I1]], 0] [2, 34] [1, 1]

  // CHECK:        %[[SLICE_2_IN:.+]] = tensor.extract_slice %[[OUTSLICE_1_IN]][0, 0] [2, 16] [1, 1]
  // CHECK:        %[[SLICE_2:.+]] = tensor.extract_slice %[[OUTSLICE_1]][0, 0] [2, 16] [1, 1]
  // CHECK:        %[[LOOPRES:.+]] = scf.for %[[I2:.+]] = %{{.*}} to %{{.*}} step %{{.*}} iter_args(%[[ITERARG_2:.+]] = %[[SLICE_2]])
  // CHECK:          %[[INSLICE_2:.+]] = tensor.extract_slice %[[SLICE_2_IN]][0, %[[I2]]] [2, 8] [1, 1]
  // CHECK:          %[[OUTSLICE_2:.+]] = tensor.extract_slice %[[ITERARG_2]][0, %[[I2]]] [2, 8] [1, 1]
  // CHECK:          %[[RESSLICE_1:.+]] = linalg.generic {{.*}} ins(%[[INSLICE_2]] : tensor<2x8xf32>) outs(%[[OUTSLICE_2]] : tensor<2x8xf32>)
  // CHECK:          %[[RESPARTIAL:.+]] = tensor.insert_slice %[[RESSLICE_1]] into %[[ITERARG_2]]
  // CHECK:          scf.yield %[[RESPARTIAL]]

  // CHECK:        %[[INSERTED:.+]] = tensor.insert_slice %[[LOOPRES]] into %[[OUTSLICE_1]][0, 0] [2, 16] [1, 1]
  // CHECK:        %[[OUTSLICE_3:.+]] = tensor.extract_slice %[[INSERTED]][0, 16] [2, 18] [1, 1]
  // CHECK:        scf.for %{{.*}} iter_args(%{{.*}} = %[[OUTSLICE_3]])
  // CHECK-COUNT-2:  tensor.extract_slice
  // CHECK:          linalg.generic {{.*}} ins(%{{.*}} : tensor<2x9xf32>)
  // CHECK:          tensor.insert_slice
  // CHECK:          scf.yield
  // CHECK:        %[[INSERTED_2:.+]] = tensor.insert_slice %{{.*}} into %[[INSERTED]]
  // CHECK:        %[[INSERTED_3:.+]] = tensor.insert_slice %[[INSERTED_2]] into %[[ITERARG_1]]
  // CHECK:        scf.yield %[[INSERTED_3]]

  // CHECK:        tensor.insert_slice
  // CHECK:        tensor.extract_slice
  // CHECK:        scf.for
  // CHECK-COUNT-2:  tensor.extract_slice
  // CHECK:          scf.for
  // CHECK-COUNT-2:    tensor.extract_slice
  // CHECK:            linalg.generic {{.*}} ins(%{{.*}} : tensor<3x8xf32>)
  // CHECK:            tensor.insert_slice
  // CHECK:            scf.yield
  // CHECK:          tensor.insert_slice
  // CHECK:          tensor.extract_slice
  // CHECK:          scf.for
  // CHECK-COUNT-2:    tensor.extract_slice
  // CHECK:            linalg.generic {{.*}} ins(%{{.*}} : tensor<3x9xf32>)
  // CHECK:            tensor.insert_slice
  // CHECK:            scf.yield
  // CHECK-COUNT-2:  tensor.insert_slice
  // CHECK:          scf.yield
  // CHECK:        %[[RESULT:.+]] = tensor.insert_slice
  // CHECK:        return %[[RESULT]]

  return %0 : tensor<10x34xf32>
}
