function compute_feature_scales(config)
    image_size = config.image_size
    image_size_downsampled = image_size
    for _ in 1:(config.downsample_times)
        image_size_downsampled = image_size_downsampled .÷ 2
    end
    scales = [(image_size_downsampled..., config.num_channels[1])]
    for i in 2:(config.num_branches)
        push!(scales, ((scales[end][1:2] .÷ 2)..., config.num_channels[i]))
    end
    return Tuple(scales)
end

function get_default_experiment_configuration(::Val{:CIFAR10}, ::Val{:TINY})
    return (
        num_layers=10,
        num_classes=10,
        dropout_rate=0.25f0,
        group_count=8,
        weight_norm=true,
        downsample_times=0,
        expansion_factor=5,
        post_gn_affine=false,
        image_size=(32, 32),
        num_modules=1,
        num_branches=2,
        block_type=:basic,
        big_kernels=(0, 0),
        head_channels=(8, 16),
        num_blocks=(1, 1),
        num_channels=(24, 24),
        fuse_method=:sum,
        final_channelsize=200,
        fwd_maxiters=18,
        bwd_maxiters=20,
        continuous=true,
        stop_mode=:rel_deq_best,
        nepochs=20,
        jfb=false,
        augment=false,
        model_type=:VANILLA,
        abstol=5.0f-2,
        reltol=5.0f-2,
        ode_solver=VCABM3(),
        pretrain_epochs=8,
        lr_scheduler=:COSINE,
        optimiser=:ADAM,
        eta=0.001f0 * scaling_factor(),
    )
end

function get_default_experiment_configuration(::Val{:CIFAR10}, ::Val{:LARGE})
    return (
        num_layers=10,
        num_classes=10,
        dropout_rate=0.3f0,
        group_count=8,
        weight_norm=true,
        downsample_times=0,
        expansion_factor=5,
        post_gn_affine=false,
        image_size=(32, 32),
        num_modules=1,
        num_branches=4,
        block_type=:basic,
        big_kernels=(0, 0, 0, 0),
        head_channels=(14, 28, 56, 112),
        num_blocks=(1, 1, 1, 1),
        num_channels=(32, 64, 128, 256),
        fuse_method=:sum,
        final_channelsize=1680,
        fwd_maxiters=18,
        bwd_maxiters=20,
        continuous=true,
        stop_mode=:rel_deq_best,
        nepochs=220,
        jfb=false,
        augment=true,
        model_type=:VANILLA,
        abstol=5.0f-2,
        reltol=5.0f-2,
        ode_solver=VCABM3(),
        pretrain_epochs=8,
        lr_scheduler=:COSINE,
        optimiser=:ADAM,
        eta=0.001f0 * scaling_factor(),
    )
end

function get_default_experiment_configuration(::Val{:IMAGENET}, ::Val{:SMALL})
    return (
        num_layers=4,
        num_classes=1000,
        dropout_rate=0.0f0,
        group_count=8,
        weight_norm=true,
        downsample_times=2,
        expansion_factor=5,
        post_gn_affine=true,
        image_size=(224, 224),
        num_modules=1,
        num_branches=4,
        block_type=:basic,
        big_kernels=(0, 0, 0, 0),
        head_channels=(24, 48, 96, 192),
        num_blocks=(1, 1, 1, 1),
        num_channels=(32, 64, 128, 256),
        fuse_method=:sum,
        final_channelsize=2048,
        fwd_maxiters=27,
        bwd_maxiters=28,
        continuous=true,
        stop_mode=:rel_deq_best,
        nepochs=100,
        jfb=false,
        model_type=:VANILLA,
        abstol=5.0f-2,
        reltol=5.0f-2,
        ode_solver=VCABM3(),
        pretrain_epochs=18,
        lr_scheduler=:COSINE,
        optimiser=:SGD,
        eta=0.05f0 * scaling_factor(),
        weight_decay=0.00005f0,
        momentum=0.9f0,
        nesterov=true,
    )
end

function get_default_experiment_configuration(::Val{:IMAGENET}, ::Val{:LARGE})
    return (
        num_layers=4,
        num_classes=1000,
        dropout_rate=0.0f0,
        group_count=8,
        weight_norm=true,
        downsample_times=2,
        expansion_factor=5,
        post_gn_affine=true,
        image_size=(224, 224),
        num_modules=1,
        num_branches=4,
        block_type=:basic,
        big_kernels=(0, 0, 0, 0),
        head_channels=(32, 64, 128, 256),
        num_blocks=(1, 1, 1, 1),
        num_channels=(80, 160, 320, 640),
        fuse_method=:sum,
        final_channelsize=2048,
        fwd_maxiters=27,
        bwd_maxiters=28,
        continuous=true,
        stop_mode=:rel_deq_best,
        nepochs=100,
        jfb=false,
        model_type=:VANILLA,
        abstol=5.0f-2,
        reltol=5.0f-2,
        ode_solver=VCABM3(),
        pretrain_epochs=18,
        lr_scheduler=:COSINE,
        optimiser=:SGD,
        eta=0.05f0 * scaling_factor(),
        weight_decay=0.00005f0,
        momentum=0.9f0,
        nesterov=true,
    )
end

function get_default_experiment_configuration(::Val{:IMAGENET}, ::Val{:XL})
    return (
        num_layers=4,
        num_classes=1000,
        dropout_rate=0.0f0,
        group_count=8,
        weight_norm=true,
        downsample_times=2,
        expansion_factor=5,
        post_gn_affine=true,
        image_size=(224, 224),
        num_modules=1,
        num_branches=4,
        block_type=:basic,
        big_kernels=(0, 0, 0, 0),
        head_channels=(32, 64, 128, 256),
        num_blocks=(1, 1, 1, 1),
        num_channels=(88, 176, 352, 704),
        fuse_method=:sum,
        final_channelsize=2048,
        fwd_maxiters=27,
        bwd_maxiters=28,
        continuous=true,
        stop_mode=:rel_deq_best,
        nepochs=100,
        jfb=false,
        model_type=:VANILLA,
        abstol=5.0f-2,
        reltol=5.0f-2,
        ode_solver=VCABM3(),
        pretrain_epochs=18,
        lr_scheduler=:COSINE,
        optimiser=:SGD,
        eta=0.05f0 * scaling_factor(),
        weight_decay=0.00005f0,
        momentum=0.9f0,
        nesterov=true,
    )
end

function get_experiment_configuration(dataset::Val, model_size::Val; kwargs...)
    return merge(get_default_experiment_configuration(dataset, model_size), kwargs)
end
