// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * astar_problem.cuh
 *
 * @brief GPU Storage management Structure for A* Problem Data
 */


#pragma once

#include <limits>
#include <gunrock/app/problem_base.cuh>
#include <gunrock/util/memset_kernel.cuh>
#include <gunrock/util/array_utils.cuh>
#include <gunrock/priority_queue/kernel.cuh>
#include <gunrock/util/track_utils.cuh>

namespace gunrock {
namespace app {
namespace astar {

/**
 * @brief A* Path Finding Problem structure stores device-side vectors for doing A* computing on the GPU.
 *
 * @tparam _VertexId            Type of signed integer to use as vertex id (e.g., uint32)
 * @tparam _SizeT               Type of unsigned integer to use for array indexing. (e.g., uint32)
 * @tparam _Value               Type of value used for computed values.
 * @tparam _MARK_PREDECESSORS   Whether to mark predecessor value for each node.
 */
template <
    typename    VertexId,
    typename    SizeT,
    typename    Value,
    //bool        _MARK_PREDECESSORS>
    bool        _MARK_PATHS,
    int         DISTANCE_HEURISTIC>
struct ASTARProblem : ProblemBase<VertexId, SizeT, Value,
    true,//_MARK_PREDECESSORS, //MARK_PREDECESSORS
    false> //ENABLE_IDEMPOTENCE
    //false, //USE_DOUBLE_BUFFER
    //false, //ENABLE_BACKWARD
    //false, //KEEP_ORDER
    //false> //KEEP_NODE_NUM
{
    static const bool MARK_PATHS            = _MARK_PATHS;
    static const bool MARK_PREDECESSORS     = true;//_MARK_PREDECESSORS;
    static const bool ENABLE_IDEMPOTENCE    = false;
    static const int  MAX_NUM_VERTEX_ASSOCIATES = MARK_PATHS ? 1 : 0;//MARK_PREDECESSORS ? 1 : 0;
    static const int  MAX_NUM_VALUE__ASSOCIATES = 1;
    typedef ProblemBase   <VertexId, SizeT, Value,
        MARK_PREDECESSORS, ENABLE_IDEMPOTENCE> BaseProblem;
    typedef DataSliceBase <VertexId, SizeT, Value,
        MAX_NUM_VERTEX_ASSOCIATES, MAX_NUM_VALUE__ASSOCIATES> BaseDataSlice;
    typedef unsigned char MaskT;
    
    typedef gunrock::priority_queue::PriorityQueue<VertexId, SizeT>
        NearFarPriorityQueue;

    //Helper structures

    /**
     * @brief Data slice structure which contains A* problem specific data.
     */
    struct DataSlice : BaseDataSlice
    {
        // device storage arrays
        util::Array1D<SizeT, Value       >    g_cost  ;     /**< Used for source distance */
        util::Array1D<SizeT, Value       >    f_cost  ;     /**< Used for source distance */
        util::Array1D<SizeT, Value       >    weights ;     /**< Used for storing edge weights */
        util::Array1D<SizeT, VertexId    >    visit_lookup;
        util::Array1D<SizeT, float       >    delta;
        util::Array1D<SizeT, int         >    marker;
        util::Array1D<SizeT, Value       >    bfs_levels;   /**< Used for storing BFS levels */
        util::Array1D<SizeT, VertexId    >    dst_node;   /**< Used for storing dst node ID */
        util::Array1D<SizeT, int     >        quit_flag;     /**< Finish flag for label propagation, indicates that all labels are stable.*/
        util::Array1D<SizeT, Value       >    sample_weight;   /**< Used for storing sample weight (avg or min)*/
        util::Array1D<SizeT, VertexId    >    original_vertex;
        util::Array1D<SizeT, Value       >    pointx;
        util::Array1D<SizeT, Value       >    pointy;

        NearFarPriorityQueue *pq;

        /*
         * @brief Default constructor
         */
        DataSlice() : BaseDataSlice()
        {
            g_cost          .SetName("g_cost"          );
            f_cost          .SetName("f_cost"          );
            weights         .SetName("weights"         );
            visit_lookup    .SetName("visit_lookup"         );
            delta         .SetName("delta"         );
            marker         .SetName("marker"         );
            bfs_levels      .SetName("bfs_levels"      );
            dst_node        .SetName("dst_node"        );
            quit_flag       .SetName("quit_flag"       );
            sample_weight   .SetName("sample_weight"   );
            original_vertex .SetName("original_vertex" );
            pointx.SetName("pointx");
            pointy.SetName("pointy");
            pq = new NearFarPriorityQueue;
        }

        /*
         * @brief Default destructor
         */
        virtual ~DataSlice()
        {
            Release();
        }

        cudaError_t Release()
        {
            cudaError_t retval = cudaSuccess;
            if (retval = util::SetDevice(this->gpu_idx)) return retval;
            if (retval = BaseDataSlice::Release()) return retval;
            if (retval = g_cost        .Release()) return retval;
            if (retval = f_cost        .Release()) return retval;
            if (retval = weights       .Release()) return retval;
            if (retval = visit_lookup  .Release()) return retval;
            if (retval = delta         .Release()) return retval;
            if (retval = marker        .Release()) return retval;
            if (retval = dst_node      .Release()) return retval;
            if (retval = quit_flag      .Release()) return retval;
            if (retval = sample_weight .Release()) return retval;
            if (retval = bfs_levels    .Release()) return retval;
            if (retval = pointx    .Release()) return retval;
            if (retval = pointy    .Release()) return retval;
            if (retval = original_vertex.Release()) return retval;
            delete pq;
            return retval;
        }

        bool HasNegativeValue(Value* vals, size_t len)
        {
            for (int i = 0; i < len; ++i)
                if (vals[i] < 0.0) return true;
            return false;
        }

        /**
         * @brief initialization function.
         *
         * @param[in] num_gpus Number of the GPUs used.
         * @param[in] gpu_idx GPU index used for testing.
         * @param[in] num_vertex_associate Number of vertices associated.
         * @param[in] num_value__associate Number of value associated.
         * @param[in] graph Pointer to the graph we process on.
         * @param[in] num_in_nodes
         * @param[in] num_out_nodes
         * @param[in] original_vertex
         * @param[in] delta_factor Delta factor for delta-stepping.
         * @param[in] queue_sizing Maximum queue sizing factor.
         * @param[in] in_sizing
         *
         * \return cudaError_t object Indicates the success of all CUDA calls.
         */
        cudaError_t Init(
            int   num_gpus,
            int   gpu_idx,
            bool  use_double_buffer,
            //int   num_vertex_associate,
            //int   num_value__associate,
            Csr<VertexId, SizeT, Value> *graph,
            GraphSlice<VertexId, SizeT, Value> *graph_slice,
            SizeT *num_in_nodes,
            SizeT *num_out_nodes,
            Value *latitudes,
            Value *longitudes,
            //VertexId *original_vertex,
            int   delta_factor = 16,
            float queue_sizing = 2.0,
            float in_sizing    = 1.0,
            bool  skip_makeout_selection = false,
            bool  keep_node_num = false)
        {
            cudaError_t retval  = cudaSuccess;

            // Check if there are negative weights.
            if (HasNegativeValue(graph->edge_values, graph->edges)) {
                GRError(gunrock::util::GR_UNSUPPORTED_INPUT_DATA,
                        "Contains edges with negative weights. Dijkstra's algorithm"
                        "doesn't support the input data.",
                        __FILE__,
                        __LINE__);
                return retval;
            }
            if (retval = BaseDataSlice::Init(
                num_gpus,
                gpu_idx,
                use_double_buffer,
                //num_vertex_associate,
                //num_value__associate,
                graph,
                num_in_nodes,
                num_out_nodes,
                in_sizing,
                skip_makeout_selection)) return retval;

                util::GRError(pq->Init(graph->edges, queue_sizing),
                    "Priority Queue A* Initialization Failed", __FILE__,
                    __LINE__);

            if (retval = g_cost      .Allocate(graph->nodes, util::DEVICE)) return retval;
            if (retval = f_cost      .Allocate(graph->nodes, util::DEVICE)) return retval;
            if (retval = weights     .Allocate(graph->edges, util::DEVICE)) return retval;
            if (retval = delta      .Allocate(1, util::DEVICE)) return retval;
            if (retval = visit_lookup      .Allocate(graph->nodes, util::DEVICE)) return retval;
            if (retval = marker      .Allocate(graph->nodes, util::DEVICE)) return retval;
            if (retval = dst_node    .Allocate(1, util::DEVICE)) return retval;
            if (retval = quit_flag  .Allocate(1, util::HOST | util::DEVICE)) return retval;
            if (retval = sample_weight.Allocate(1, util::DEVICE)) return retval;
            if (retval = this->labels.Allocate(graph->nodes, util::DEVICE)) return retval;
            if (DISTANCE_HEURISTIC) {
                if (retval = pointx  .Allocate(graph->nodes, util::DEVICE)) return retval;
                if (retval = pointy  .Allocate(graph->nodes, util::DEVICE)) return retval;
                if (retval = bfs_levels  .Allocate(1, util::DEVICE)) return retval;
                pointx.SetPointer(latitudes, graph->nodes, util::HOST);
                if (retval = pointx.Move(util::HOST, util::DEVICE)) return retval;
                pointy.SetPointer(longitudes, graph->nodes, util::HOST);
                if (retval = pointy.Move(util::HOST, util::DEVICE)) return retval;
            } else {
                if (retval = bfs_levels  .Allocate(graph->nodes, util::DEVICE)) return retval;
                if (retval = pointx  .Allocate(1, util::DEVICE)) return retval;
                if (retval = pointy  .Allocate(1, util::DEVICE)) return retval;
                bfs_levels.SetPointer(graph->node_values, graph->nodes, util::HOST);
                if (retval = bfs_levels.Move(util::HOST, util::DEVICE)) return retval;
            }


            float _delta = 1000000;
            printf("delta value:%f\n", _delta);
            delta.SetPointer(&_delta, util::HOST);
            if (retval = delta.Move(util::HOST, util::DEVICE)) return retval;
            weights.SetPointer(graph->edge_values, graph->edges, util::HOST);
            if (retval = weights.Move(util::HOST, util::DEVICE)) return retval; 

            if (MARK_PATHS)//(MARK_PREDECESSORS)
            {
                if (retval = this->preds.Allocate(graph->nodes,util::DEVICE)) return retval;
            } else {
                if (retval = this->preds.Release()) return retval;
            }

            if (num_gpus >1)
            {
                this->value__associate_orgs[0] = g_cost.GetPointer(util::DEVICE);
                this->value__associate_orgs[0] = f_cost.GetPointer(util::DEVICE);
                if (MARK_PATHS)//(MARK_PREDECESSORS)
                {
                    this->vertex_associate_orgs[0] = this->preds.GetPointer(util::DEVICE);
                    if (!keep_node_num)
                    this -> original_vertex.SetPointer(
                        graph_slice -> original_vertex.GetPointer(util::DEVICE),
                        graph_slice -> original_vertex.GetSize(),
                        util::DEVICE);
                    if (retval = this->vertex_associate_orgs.Move(util::HOST, util::DEVICE)) return retval;
                }
                if (retval = this->value__associate_orgs.Move(util::HOST, util::DEVICE)) return retval;
            }

            return retval;
        } // Init

        /*
         * @brief Estimate delta factor for delta-stepping.
         *
         * @param[in] graph Reference to the graph we process on.
         *
         * \return float Delta factor.
         */
        float EstimatedDelta(const Csr<VertexId, Value, SizeT> &graph) {
            double  avgV = graph.average_edge_value;
            int     avgD = graph.average_degree;
            printf("avgV:%f, avgD:%d\n", avgV, avgD);
            return avgV * 32 / avgD;
        }

        /**
         * @brief Reset problem function. Must be called prior to each run.
         *
         * @param[in] frontier_type The frontier type (i.e., edge/vertex/mixed).
         * @param[in] graph_slice Pointer to the graph slice we process on.
         * @param[in] queue_sizing Size scaling factor for work queue allocation (e.g., 1.0 creates n-element and m-element vertex and edge frontiers, respectively).
         * @param[in] queue_sizing1 Size scaling factor for work queue allocation.
         *
         * \return cudaError_t object Indicates the success of all CUDA calls.
         */
        cudaError_t Reset(
            FrontierType frontier_type,
            GraphSlice<VertexId, SizeT, Value>  *graph_slice,
            double queue_sizing = 2.0,
            double queue_sizing1 = -1.0)
        {
            cudaError_t retval = cudaSuccess;
            SizeT nodes = graph_slice -> nodes;
            SizeT edges = graph_slice -> edges;
            SizeT new_frontier_elements[2] = {0,0};
            if (queue_sizing1 < 0) queue_sizing1 = queue_sizing;

            for (int gpu = 0; gpu < this -> num_gpus; gpu++)
                this -> wait_marker[gpu] = 0;
            for (int i=0; i<4; i++)
            for (int gpu = 0; gpu < this -> num_gpus * 2; gpu++)
            for (int stage=0; stage < this -> num_stages; stage++)
                this -> events_set[i][gpu][stage] = false;
            for (int gpu = 0; gpu < this -> num_gpus; gpu++)
            for (int i=0; i<2; i++)
                this -> in_length[i][gpu] = 0;
            for (int peer=0; peer<this->num_gpus; peer++)
                this -> out_length[peer] = 1;

            for (int peer=0;peer<(this->num_gpus > 1 ? this->num_gpus+1 : 1);peer++)
            for (int i=0; i < 2; i++)
            {
                double queue_sizing_ = i==0?queue_sizing : queue_sizing1;
                switch (frontier_type) {
                    case VERTEX_FRONTIERS :
                        // O(n) ping-pong global vertex frontiers
                        new_frontier_elements[0] = double(this->num_gpus>1? graph_slice->in_counter[peer]:nodes) * queue_sizing_ +2;
                        new_frontier_elements[1] = new_frontier_elements[0];
                        break;

                    case EDGE_FRONTIERS :
                        // O(m) ping-pong global edge frontiers
                        new_frontier_elements[0] = double(edges) * queue_sizing_ +2;
                        new_frontier_elements[1] = new_frontier_elements[0];
                        break;

                    case MIXED_FRONTIERS :
                        // O(n) global vertex frontier, O(m) global edge frontier
                        new_frontier_elements[0] = double(this->num_gpus>1? graph_slice->in_counter[peer]:nodes) * queue_sizing_ +2;
                        new_frontier_elements[1] = double(edges) * queue_sizing_ +2;
                        break;
                }

                // Iterate through global frontier queue setups
                //for (int i = 0; i < 2; i++)
                {
                    if (peer == this->num_gpus && i == 1) continue;
                    if (new_frontier_elements[i] > edges + 2 && queue_sizing_ > 10) new_frontier_elements[i] = edges + 2;
                    //if (peer == this->num_gpus && new_frontier_elements[i] > nodes * this->num_gpus) new_frontier_elements[i] = nodes * this->num_gpus;
                    if (this->frontier_queues[peer].keys[i].GetSize() < new_frontier_elements[i]) {

                        // Free if previously allocated
                        if (retval = this->frontier_queues[peer].keys[i].Release()) return retval;

                        // Free if previously allocated
                        if (false) {
                            if (retval = this->frontier_queues[peer].values[i].Release()) return retval;
                        }
                        //frontier_elements[peer][i] = new_frontier_elements[i];

                        if (retval = this->frontier_queues[peer].keys[i].Allocate(new_frontier_elements[i],util::DEVICE)) return retval;
                        if (false) {
                            if (retval = this->frontier_queues[peer].values[i].Allocate(new_frontier_elements[i],util::DEVICE)) return retval;
                        }
                    } //end if
                } // end for i<2

                if (peer == this->num_gpus || i == 1)
                {
                    continue;
                }
                //if (peer == num_gpu) continue;
                SizeT max_elements = new_frontier_elements[0];
                if (new_frontier_elements[1] > max_elements) max_elements=new_frontier_elements[1];
                if (max_elements > nodes) max_elements = nodes;
                if (this->scanned_edges[peer].GetSize() < max_elements)
                {
                    if (retval = this->scanned_edges[peer].Release()) return retval;
                    if (retval = this->scanned_edges[peer].Allocate(max_elements, util::DEVICE)) return retval;
                }
            }

            // Allocate output g_cost, f_cost if necessary
            if (this->g_cost      .GetPointer(util::DEVICE) == NULL)
                if (retval = this->g_cost   .Allocate(nodes, util::DEVICE)) return retval;
            if (this->f_cost      .GetPointer(util::DEVICE) == NULL)
                if (retval = this->f_cost   .Allocate(nodes, util::DEVICE)) return retval;

            if (this->preds       .GetPointer(util::DEVICE) == NULL && MARK_PATHS)//MARK_PREDECESSORS)
                if (retval = this->preds       .Allocate(nodes, util::DEVICE)) return retval;

            if (this -> labels    .GetPointer(util::DEVICE) == NULL)
                if (retval = this -> labels    .Allocate(nodes, util::DEVICE)) return retval;

            if (this->visit_lookup.GetPointer(util::DEVICE) == NULL)
                if (retval = this->visit_lookup.Allocate(nodes, util::DEVICE)) return retval;

            if (MARK_PATHS)//(MARK_PREDECESSORS) 
                util::MemsetIdxKernel<<<256, 1024>>>(
                    this->preds.GetPointer(util::DEVICE), nodes);

            util::MemsetKernel<<<256, 1024>>>(
                this->g_cost   .GetPointer(util::DEVICE), 
                util::MaxValue<Value>(), 
                nodes);

            util::MemsetKernel<<<256, 1024>>>(
                this->f_cost   .GetPointer(util::DEVICE), 
                util::MaxValue<Value>(), 
                nodes);

            util::MemsetKernel<<<256, 1024>>>(
                this -> labels .GetPointer(util::DEVICE),
                util::InvalidValue<VertexId>(),
                nodes);

            quit_flag[0] = 0;
            if (retval = quit_flag.Move(util::HOST, util::DEVICE)) return retval;

            util::MemsetKernel<<<256, 1024>>>(this->visit_lookup.GetPointer(util::DEVICE), (VertexId)-1, nodes);
            util::MemsetKernel<<<256, 1024>>>(marker.GetPointer(util::DEVICE), (int)0, nodes);

            return retval;
        }
    }; // DataSlice

    // Members
    // Set of data slices (one for each GPU)
    util::Array1D<SizeT, DataSlice>          *data_slices;
    // Methods

    /**
     * @brief ASTARProblem default constructor
     */

    ASTARProblem() : BaseProblem(
        false, // use_double_buffer
        false, // enable_backward
        false, // keep_order
        true,  // keep_node_num
        false, // skip_makeout_selection
        true)  // unified_receive
    {
        data_slices = NULL;
    }

    /**
     * @brief ASTARProblem default destructor
     */
    virtual ~ASTARProblem()
    {
        Release();
    }

    cudaError_t Release()
    {
        cudaError_t retval = cudaSuccess;
        if (data_slices==NULL) return retval;
        for (int i = 0; i < this->num_gpus; ++i)
        {
            if (retval = util::SetDevice(this->gpu_idx[i])) return retval;
            if (retval = data_slices[i].Release()) return retval;
        }
        delete[] data_slices;data_slices=NULL;
        if (retval = BaseProblem::Release()) return retval;
        return retval;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Copy result preds computed on the GPU back to host-side vectors.
     *
     * @param[out] h_preds host-side vector to store computed node predecessors (used for extracting the actual shortest path).
     *
     *\return cudaError_t object Indicates the success of all CUDA calls.
     */
    cudaError_t Extract(VertexId *h_preds)
    {
        cudaError_t retval = cudaSuccess;

        if (this->num_gpus == 1)
        {

            // Set device
            if (retval = util::SetDevice(this->gpu_idx[0])) return retval;

            if (MARK_PATHS)//(MARK_PREDECESSORS)
            {
                data_slices[0]->preds.SetPointer(h_preds);
                if (retval = data_slices[0]->preds.Move(util::DEVICE,util::HOST)) return retval;
            }

        } else {
            VertexId **th_preds =new VertexId*[this->num_gpus];
            for (int gpu=0;gpu<this->num_gpus;gpu++)
            {
                if (retval = util::SetDevice(this->gpu_idx[gpu])) return retval;
                if (MARK_PATHS)//(MARK_PREDECESSORS) 
                {
                    if (retval = data_slices[gpu]->preds.Move(util::DEVICE,util::HOST)) return retval;
                    th_preds[gpu]=data_slices[gpu]->preds.GetPointer(util::HOST);
                }
            } //end for(gpu)

            for (VertexId node=0;node<this->nodes;node++) {
                printf("OutOfBound: node = %d, partition = %d, convertion = %d\n",
                       node, this->partition_tables[0][node], this->convertion_tables[0][node]);
                       //data_slices[this->partition_tables[0][node]]->distance.GetSize());
                fflush(stdout);
            }

           if (MARK_PATHS)//(MARK_PREDECESSORS)
                for (VertexId node=0;node<this->nodes;node++)
                    h_preds[node]=th_preds[this->partition_tables[0][node]][this->convertion_tables[0][node]];
            for (int gpu=0;gpu<this->num_gpus;gpu++)
            {
                if (retval = data_slices[gpu]->preds.Release(util::HOST)) return retval;
            }
            delete[] th_preds ;th_preds =NULL;
        } //end if (data_slices.size() ==1)

        return retval;
    }

    /**
     * @brief initialization function.
     *
     * @param[in] stream_from_host Whether to stream data from host.
     * @param[in] graph Pointer to the CSR graph object we process on. @see Csr
     * @param[in] inversegraph Pointer to the inversed CSR graph object we process on.
     * @param[in] num_gpus Number of the GPUs used.
     * @param[in] gpu_idx GPU index used for testing.
     * @param[in] partition_method Partition method to partition input graph.
     * @param[in] streams CUDA stream.
     * @param[in] delta_factor delta factor for delta-stepping.
     * @param[in] queue_sizing Maximum queue sizing factor.
     * @param[in] in_sizing
     * @param[in] partition_factor Partition factor for partitioner.
     * @param[in] partition_seed Partition seed used for partitioner.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    cudaError_t Init(
            bool          stream_from_host,       // Only meaningful for single-GPU
            Value*        latitudes,
            Value*        longitudes,
            Csr<VertexId, SizeT, Value>
                         *graph,
            Csr<VertexId, SizeT, Value>
                         *inversegraph      = NULL,
            int           num_gpus          = 1,
            int          *gpu_idx           = NULL,
            std::string   partition_method  = "random",
            cudaStream_t *streams           = NULL,
            int           delta_factor      = 16,
            float         queue_sizing      = 2.0,
            float         in_sizing         = 1.0,
            float         partition_factor  = -1.0,
            int           partition_seed    = -1)
    {
        cudaError_t retval = cudaSuccess;
        if (retval = BaseProblem::Init(
            stream_from_host,
            graph,
            inversegraph,
            num_gpus,
            gpu_idx,
            partition_method,
            queue_sizing,
            partition_factor,
            partition_seed))
            return retval; 

        // No data in DataSlice needs to be copied from host

        data_slices = new util::Array1D<SizeT, DataSlice>[this->num_gpus];

        for (int gpu=0;gpu<this->num_gpus;gpu++)
        {
            data_slices[gpu].SetName("data_slices[]");
            if (retval = util::SetDevice(this->gpu_idx[gpu])) return retval;
            if (retval = data_slices[gpu].Allocate(1, util::DEVICE | util::HOST)) return retval;
            DataSlice* _data_slice = data_slices[gpu].GetPointer(util::HOST);
            _data_slice->streams.SetPointer(&streams[gpu*num_gpus*2], num_gpus*2);

            if (retval = _data_slice->Init(
                this->num_gpus,
                this->gpu_idx[gpu],
                //this->num_gpus > 1? (MARK_PATHS ? 1 : 0) : 0,
                //this->num_gpus > 1? 1 : 0,
                this->use_double_buffer,
                &(this->sub_graphs[gpu]),
                this -> graph_slices[gpu],
                this->num_gpus > 1? this->graph_slices[gpu]->in_counter.GetPointer(util::HOST) : NULL,
                this->num_gpus > 1? this->graph_slices[gpu]->out_counter.GetPointer(util::HOST): NULL,
                //this->num_gpus > 1? this->graph_slices[gpu]->original_vertex.GetPointer(util::HOST) : NULL,
                latitudes,
                longitudes,
                delta_factor,
                queue_sizing,
                in_sizing,
                this -> skip_makeout_selection,
                this -> keep_node_num))
                return retval;
        } // end for (gpu)

        return retval;
    }

    /**
     * @brief Reset problem function. Must be called prior to each run.
     *
     * @param[in] src Source node to start.
     * @param[in] frontier_type The frontier type (i.e., edge/vertex/mixed).
     * @param[in] queue_sizing Size scaling factor for work queue allocation (e.g., 1.0 creates n-element and m-element vertex and edge frontiers, respectively).
     * @param[in] queue_sizing1
     *
     *  \return cudaError_t object Indicates the success of all CUDA calls.
     */
    cudaError_t Reset(
            VertexId    src,
            VertexId    dst,
            Value       sample_weight,
            FrontierType frontier_type,
            double queue_sizing,
            double queue_sizing1 = -1)
    {

        cudaError_t retval = cudaSuccess;
        if (queue_sizing1 < 0) queue_sizing1 = queue_sizing;

        for (int gpu = 0; gpu < this->num_gpus; ++gpu) {
            // Set device
            if (retval = util::SetDevice(this->gpu_idx[gpu])) return retval;
            if (retval = data_slices[gpu] -> Reset(
                frontier_type, this->graph_slices[gpu],
                queue_sizing, queue_sizing1)) return retval;
            if (retval = data_slices[gpu].Move(util::HOST, util::DEVICE)) return retval;
        }

        // Fillin the initial input_queue for A* problem
        int gpu;
        VertexId tsrc;
        if (this->num_gpus <= 1)
        {
            gpu=0;tsrc=src;
        } else {
            gpu = this->partition_tables [0][src];
            tsrc= this->convertion_tables[0][src];
        }
        if (retval = util::SetDevice(this->gpu_idx[gpu])) return retval;
        if (retval = util::GRError(cudaMemcpy(
                        data_slices[gpu]->frontier_queues[0].keys[0].GetPointer(util::DEVICE),
                        &tsrc,
                        sizeof(VertexId),
                        cudaMemcpyHostToDevice),
                    "ASTARProblem cudaMemcpy frontier_queues failed", __FILE__, __LINE__)) return retval;

        if (retval = util::GRError(cudaMemcpy(
                        data_slices[gpu]->dst_node.GetPointer(util::DEVICE),
                        &dst,
                        sizeof(VertexId),
                        cudaMemcpyHostToDevice),
                    "ASTARProblem cudaMemcpy dst_node failed", __FILE__, __LINE__)) return retval;

        if (retval = util::GRError(cudaMemcpy(
                        data_slices[gpu]->sample_weight.GetPointer(util::DEVICE),
                        &sample_weight,
                        sizeof(Value),
                        cudaMemcpyHostToDevice),
                    "ASTARProblem cudaMemcpy sample_weight failed", __FILE__, __LINE__)) return retval;
        Value src_distance = 0;
        if (retval = util::GRError(cudaMemcpy(
                        data_slices[gpu]->g_cost.GetPointer(util::DEVICE)+tsrc,
                        &src_distance,
                        sizeof(Value),
                        cudaMemcpyHostToDevice),
                    "ASTARProblem cudaMemcpy frontier_queues failed", __FILE__, __LINE__)) return retval;
        if (retval = util::GRError(cudaMemcpy(
                        data_slices[gpu]->f_cost.GetPointer(util::DEVICE)+tsrc,
                        &src_distance,
                        sizeof(Value),
                        cudaMemcpyHostToDevice),
                    "ASTARProblem cudaMemcpy frontier_queues failed", __FILE__, __LINE__)) return retval;

        if (MARK_PATHS)//(MARK_PREDECESSORS)
        {
            VertexId src_pred = -1;
            if (retval = util::GRError(cudaMemcpy(
                data_slices[gpu]->preds.GetPointer(util::DEVICE)+tsrc,
                &src_pred,
                sizeof(Value),
                cudaMemcpyHostToDevice),
                "ASTARProblem cudaMemcpy frontier_queues failed", __FILE__, __LINE__)) return retval;
        } 
        return retval;
    }

    /** @} */

};

} //namespace astar
} //namespace app
} //namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: