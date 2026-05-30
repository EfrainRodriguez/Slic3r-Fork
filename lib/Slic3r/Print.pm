# The slicing work horse.
# Extends C++ class Slic3r::Print
package Slic3r::Print;
use strict;
use warnings;

use File::Basename qw(basename fileparse);
use File::Spec;
use List::Util qw(min max first sum);
use JSON::PP;
use Scalar::Util qw(blessed);
use Slic3r::ExtrusionLoop ':roles';
use Slic3r::ExtrusionPath ':roles';
use Slic3r::Flow ':roles';
use Slic3r::Geometry qw(X Y Z X1 Y1 X2 Y2 MIN MAX PI scale unscale convex_hull);
use Slic3r::Geometry::Clipper qw(diff_ex union_ex intersection_ex intersection offset
    offset2 union union_pt_chained JT_ROUND JT_SQUARE diff_pl);
use Slic3r::Print::State ':steps';
use Slic3r::Surface qw(S_TYPE_BOTTOM);

our $status_cb;

sub set_status_cb {
    my ($class, $cb) = @_;
    $status_cb = $cb;
}

sub status_cb {
    return $status_cb // sub {};
}

# this value is not supposed to be compared with $layer->id
# since they have different semantics
sub total_layer_count {
    my $self = shift;
    return max(map $_->total_layer_count, @{$self->objects});
}

sub size {
    my $self = shift;
    return $self->bounding_box->size;
}

sub process {
    my ($self) = @_;
    
    ### No need to call this as we call it as part of prepare_infill()
    ### until we fix the idempotency issue.
    ###$self->status_cb->(20, "Generating perimeters");
    ###$_->make_perimeters for @{$self->objects};
    
    $self->status_cb->(70, "Infilling layers");
    $_->infill for @{$self->objects};
    
    $_->generate_support_material for @{$self->objects};
    $self->make_skirt;
    $self->make_brim;  # must come after make_skirt
    
    # time to make some statistics
    if (0) {
        eval "use Devel::Size";
        print  "MEMORY USAGE:\n";
        printf "  meshes        = %.1fMb\n", List::Util::sum(map Devel::Size::total_size($_->meshes), @{$self->objects})/1024/1024;
        printf "  layer slices  = %.1fMb\n", List::Util::sum(map Devel::Size::total_size($_->slices), map @{$_->layers}, @{$self->objects})/1024/1024;
        printf "  region slices = %.1fMb\n", List::Util::sum(map Devel::Size::total_size($_->slices), map @{$_->regions}, map @{$_->layers}, @{$self->objects})/1024/1024;
        printf "  perimeters    = %.1fMb\n", List::Util::sum(map Devel::Size::total_size($_->perimeters), map @{$_->regions}, map @{$_->layers}, @{$self->objects})/1024/1024;
        printf "  fills         = %.1fMb\n", List::Util::sum(map Devel::Size::total_size($_->fills), map @{$_->regions}, map @{$_->layers}, @{$self->objects})/1024/1024;
        printf "  print object  = %.1fMb\n", Devel::Size::total_size($self)/1024/1024;
    }
    if (0) {
        eval "use Slic3r::Test::SectionCut";
        Slic3r::Test::SectionCut->new(print => $self)->export_svg("section_cut.svg");
    }
}

sub escaped_split {
    my ($line) = @_;

    # Free up three characters for temporary replacement
    $line =~ s/%/%%/g;
    $line =~ s/#/##/g;
    $line =~ s/\?/\?\?/g;

    # replace escaped !'s
    $line =~ s/\!\!/%#\?/g;
    
    # split on non-escaped whitespace
    my @split = split /(?<=[^\!])\s+/, $line, -1;

    for my $part (@split) {
      # replace escaped whitespace with the whitespace
      $part =~ s/\!(\s+)/$1/g;

      # resub temp symbols
      $part =~ s/%#\?/\!/g;
      $part =~ s/%%/%/g;
      $part =~ s/##/#/g;
      $part =~ s/\?\?/\?/g;
    }

    return @split;
}

sub export_gcode {
    my $self = shift;
    my %params = @_;
    
    # prerequisites
    $self->process;
    
    # output everything to a G-code file
    my $output_file = $self->output_filepath($params{output_file} // '');
    $self->status_cb->(90, "Exporting G-code" . ($output_file ? " to $output_file" : ""));
    
    {
        # open output gcode file if we weren't supplied a file-handle
        my ($fh, $tempfile);
        if ($params{output_fh}) {
            $fh = $params{output_fh};
        } else {
            $tempfile = "$output_file.tmp";
            Slic3r::open(\$fh, ">", $tempfile)
                or die "Failed to open $tempfile for writing\n";
    
            # enable UTF-8 output since user might have entered Unicode characters in fields like notes
            binmode $fh, ':utf8';
        }

        Slic3r::Print::GCode->new(
            print   => $self,
            fh      => $fh,
        )->export;

        # close our gcode file
        close $fh;
        if ($tempfile) {
            my $renamed = 0;
            for my $i (1..5) {
                last if $renamed = rename Slic3r::encode_path($tempfile), Slic3r::encode_path($output_file);
                # Wait for 1/4 seconds and try to rename once again.
                select(undef, undef, undef, 0.25);
            }
            Slic3r::debugf "Failed to remove the output G-code file from $tempfile to $output_file. Is $tempfile locked?\n"
                if !$renamed;
        }
    }
    
    # run post-processing scripts
    if (@{$self->config->post_process}) {
        $self->status_cb->(95, "Running post-processing scripts");
        $self->config->setenv;
        for my $script (@{$self->config->post_process}) {
            Slic3r::debugf "  '%s' '%s'\n", $script, $output_file;
            my @parsed_script = escaped_split $script;
            my $executable = shift @parsed_script ;
            push @parsed_script, $output_file;
            # -x doesn't return true on Windows except for .exe files
            if (($^O eq 'MSWin32') ? !(-e $executable) : !(-x $executable)) {
                die "The configured post-processing script is not executable: check permissions or escape whitespace/exclamation points. ($executable) \n";
            }
            system($executable, @parsed_script);
        }
    }
}

sub export_toolpaths_json {
    my $self = shift;
    my %params = @_;

    $self->process;

    my $output_file = $self->output_filepath($params{output_file} // '');
    $output_file =~ s/\.gcode$/.json/i;
    $self->status_cb->(90, "Exporting toolpaths JSON" . ($output_file ? " to $output_file" : ""));

    my $estimated_stats = $self->_estimate_material_usage_via_gcode();

    my $encoder = JSON::PP->new->canonical->utf8;
    $encoder = $encoder->pretty if $params{pretty} // 1;
    my $json = $encoder->encode($self->toolpaths_as_json_data(estimated_stats => $estimated_stats));

    my ($fh, $tempfile);
    if ($params{output_fh}) {
        $fh = $params{output_fh};
        print {$fh} $json;
        close $fh;
        return;
    }

    $tempfile = "$output_file.tmp";
    Slic3r::open(\$fh, ">", $tempfile)
        or die "Failed to open $tempfile for writing\n";
    binmode $fh, ':utf8';
    print {$fh} $json;
    close $fh;

    my $renamed = 0;
    for my $i (1..5) {
        last if $renamed = rename Slic3r::encode_path($tempfile), Slic3r::encode_path($output_file);
        select(undef, undef, undef, 0.25);
    }
    Slic3r::debugf "Failed to rename the output JSON file from $tempfile to $output_file. Is $tempfile locked?\n"
        if !$renamed;
}

sub toolpaths_as_json_data {
    my ($self, %params) = @_;
    my $estimated_stats = $params{estimated_stats} // {};

    my @objects_data = ();
    my @layers_data = ();
    my $layer_seq_id = 0;

    for my $obj_idx (0 .. $#{$self->objects}) {
        my $object = $self->objects->[$obj_idx];

        push @objects_data, {
            object_index    => $obj_idx,
            object_id       => _safe_call($object, 'id') // _safe_call($object, 'ptr') // $obj_idx,
            copies          => [ map { [ map unscale($_), @$_ ] } @{$object->_shifted_copies} ],
            config          => _config_to_hash($object->config),
            raft_layers     => $object->config->raft_layers,
        };

        my @layers = sort { $a->print_z <=> $b->print_z } (@{$object->layers}, @{$object->support_layers});
        for my $layer (@layers) {
            my $is_support = $layer->isa('Slic3r::Layer::Support') ? JSON::PP::true : JSON::PP::false;
            my $is_raft = ($layer->id < $object->config->raft_layers) ? JSON::PP::true : JSON::PP::false;

            my $layer_data = {
                layer_seq_id     => $layer_seq_id++,
                object_index     => $obj_idx,
                layer_id         => $layer->id,
                print_z          => $layer->print_z + 0,
                slice_z          => ($layer->slice_z >= 0 ? $layer->slice_z + 0 : undef),
                height           => $layer->height + 0,
                is_support_layer => $is_support,
                is_raft_layer    => $is_raft,
                process          => {
                    layer_height            => $layer->height + 0,
                    print_speed_perimeter   => _safe_config_num($object->config, 'perimeter_speed'),
                    print_speed_infill      => _safe_config_num($object->config, 'infill_speed'),
                    print_speed_solid       => _safe_config_num($object->config, 'solid_infill_speed'),
                    print_speed_top_solid   => _safe_config_num($object->config, 'top_solid_infill_speed'),
                    support_speed           => _safe_config_num($object->config, 'support_material_speed'),
                    support_interface_speed => _safe_config_num($object->config, 'support_material_interface_speed'),
                },
                regions => [],
                support => {
                    interface_paths => [],
                    support_paths   => [],
                },
                events => [],
            };

            for my $region_id (0 .. ($self->region_count - 1)) {
                my $layerm = $layer->regions->[$region_id] or next;
                my $region = $self->get_region($region_id);
                my $region_data = {
                    region_id => $region_id,
                    config    => _config_to_hash($region->config),
                    perimeters => [],
                    infill_groups => [],
                };

                for my $perimeter_coll (@{$layerm->perimeters}) {
                    _collect_entities($perimeter_coll, $region_data->{perimeters}, {
                        source => 'perimeter',
                        region_id => $region_id,
                        layer_print_z => $layer->print_z + 0,
                        is_raft_layer => $is_raft,
                    });
                }

                for my $fill_coll (@{$layerm->fills}) {
                    my @group = ();
                    _collect_entities($fill_coll, \@group, {
                        source => 'infill',
                        region_id => $region_id,
                        layer_print_z => $layer->print_z + 0,
                        is_raft_layer => $is_raft,
                    });
                    push @{$region_data->{infill_groups}}, \@group if @group;
                }

                push @{$layer_data->{regions}}, $region_data;
            }

            if ($is_support) {
                _collect_entities($layer->support_interface_fills, $layer_data->{support}{interface_paths}, {
                    source => 'support_interface',
                    region_id => undef,
                    layer_print_z => $layer->print_z + 0,
                    is_raft_layer => $is_raft,
                });
                _collect_entities($layer->support_fills, $layer_data->{support}{support_paths}, {
                    source => 'support',
                    region_id => undef,
                    layer_print_z => $layer->print_z + 0,
                    is_raft_layer => $is_raft,
                });
            }

            _build_layer_events_with_travels($layer_data);

            push @layers_data, $layer_data;
        }
    }

    return {
        schema_version => '1.0.0',
        generator => {
            name    => 'Slic3r',
            version => $Slic3r::VERSION,
        },
        summary => {
            object_count       => scalar(@{$self->objects}),
            region_count       => $self->region_count,
            total_layer_count  => $self->total_layer_count,
            has_support        => $self->has_support_material ? JSON::PP::true : JSON::PP::false,
            used_filament_mm   => ($estimated_stats->{used_filament_mm} // ($self->total_used_filament + 0)),
            used_volume_mm3    => ($estimated_stats->{used_volume_mm3} // ($self->total_extruded_volume + 0)),
        },
        print_config => _config_to_hash($self->config),
        print_level_toolpaths => {
            skirt => do {
                my @items = ();
                _collect_entities($_, \@items, { source => 'skirt', region_id => undef, layer_print_z => undef }) for @{$self->skirt};
                \@items;
            },
            brim  => do {
                my @items = ();
                _collect_entities($_, \@items, { source => 'brim', region_id => undef, layer_print_z => undef }) for @{$self->brim};
                \@items;
            },
        },
        objects => \@objects_data,
        layers  => \@layers_data,
    };
}

sub _build_layer_events_with_travels {
    my ($layer_data) = @_;

    my @events = ();

    for my $region (@{$layer_data->{regions} // []}) {
        _flatten_paths($region->{perimeters}, \@events);
        for my $group (@{$region->{infill_groups} // []}) {
            _flatten_paths($group, \@events);
        }
    }

    _flatten_paths($layer_data->{support}{interface_paths}, \@events);
    _flatten_paths($layer_data->{support}{support_paths}, \@events);

    my @with_travel = ();
    my $prev_end;
    for my $ev (@events) {
        my $start = _path_start_point($ev);
        my $end   = _path_end_point($ev);
        if ($prev_end && $start) {
            my ($x1, $y1, $z1) = @$prev_end;
            my ($x2, $y2, $z2) = @$start;
            if (defined $x1 && defined $x2 && ($x1 != $x2 || $y1 != $y2 || $z1 != $z2)) {
                push @with_travel, {
                    type            => 'travel',
                    feature_type    => 'travel',
                    source          => 'travel',
                    region_id       => undef,
                    layer_print_z   => $z1,
                    role_id         => undef,
                    role_name       => 'travel',
                    is_bridge       => JSON::PP::false,
                    is_solid_infill => JSON::PP::false,
                    width           => 0,
                    height          => 0,
                    mm3_per_mm      => 0,
                    point_count     => 2,
                    points          => [ [ $x1, $y1, $z1 ], [ $x2, $y2, $z2 ] ],
                };
            }
        }
        push @with_travel, $ev;
        $prev_end = $end if $end;
    }

    $layer_data->{events} = \@with_travel;
}

sub _flatten_paths {
    my ($node, $out) = @_;
    return if !defined $node;
    if (ref($node) eq 'ARRAY') {
        _flatten_paths($_, $out) for @$node;
        return;
    }
    if (ref($node) eq 'HASH') {
        if (($node->{type} // '') eq 'extrusion_path') {
            push @$out, $node;
            return;
        }
        if (exists $node->{paths}) {
            _flatten_paths($_, $out) for @{$node->{paths} // []};
            return;
        }
    }
}

sub _path_start_point {
    my ($ev) = @_;
    return undef if !defined($ev) || ref($ev) ne 'HASH';
    return undef if !exists $ev->{points} || ref($ev->{points}) ne 'ARRAY' || !@{$ev->{points}};
    my $p = $ev->{points}[0];
    return undef if ref($p) ne 'ARRAY' || @$p < 2;
    return [ $p->[0] + 0, $p->[1] + 0, ($p->[2] // ($ev->{layer_print_z} // 0)) + 0 ];
}

sub _path_end_point {
    my ($ev) = @_;
    return undef if !defined($ev) || ref($ev) ne 'HASH';
    return undef if !exists $ev->{points} || ref($ev->{points}) ne 'ARRAY' || !@{$ev->{points}};
    my $p = $ev->{points}[-1];
    return undef if ref($p) ne 'ARRAY' || @$p < 2;
    return [ $p->[0] + 0, $p->[1] + 0, ($p->[2] // ($ev->{layer_print_z} // 0)) + 0 ];
}

sub _estimate_material_usage_via_gcode {
    my ($self) = @_;

    my $tmp_gcode = '';
    my $ok = eval {
        open my $fh, '>', \$tmp_gcode or die "Failed to open in-memory filehandle for estimation\n";
        Slic3r::Print::GCode->new(
            print => $self,
            fh    => $fh,
        )->export;
        close $fh;
        1;
    };

    if (!$ok) {
        warn "Warning: failed to estimate material usage for JSON export: $@\n";
        return {};
    }

    return {
        used_filament_mm => $self->total_used_filament + 0,
        used_volume_mm3  => $self->total_extruded_volume + 0,
    };
}

sub _collect_entities {
    my ($entity, $out, $meta) = @_;
    return if !defined $entity;

    if (blessed($entity) && $entity->isa('Slic3r::ExtrusionPath')) {
        push @$out, _serialize_entity($entity, $meta);
        return;
    }

    if (blessed($entity) && $entity->isa('Slic3r::ExtrusionPath::Collection')) {
        _collect_entities($_, $out, $meta) for @$entity;
        return;
    }

    if (blessed($entity) && $entity->isa('Slic3r::ExtrusionLoop')) {
        push @$out, _serialize_entity($entity, $meta);
        return;
    }

    if (ref($entity) eq 'ARRAY') {
        _collect_entities($_, $out, $meta) for @$entity;
        return;
    }
}

sub _serialize_entity {
    my ($entity, $meta) = @_;
    if (blessed($entity) && $entity->isa('Slic3r::ExtrusionLoop')) {
        my @children = map { _serialize_entity($_, $meta) } @$entity;
        return {
            source        => $meta->{source},
            region_id     => $meta->{region_id},
            layer_print_z => $meta->{layer_print_z},
            type          => 'extrusion_loop',
            feature_type  => _feature_type($meta->{source}, 'loop', undef, $meta->{is_raft_layer}),
            role_id       => _safe_call($entity, 'role'),
            role_name     => 'loop',
            path_count    => scalar(@children),
            paths         => \@children,
        };
    }

    if (ref($entity) eq 'ARRAY' && (!blessed($entity) || !$entity->isa('Slic3r::ExtrusionPath::Collection'))) {
        my @children = map { _serialize_entity($_, $meta) } @$entity;
        return {
            source        => $meta->{source},
            region_id     => $meta->{region_id},
            layer_print_z => $meta->{layer_print_z},
            type          => 'path_group',
            feature_type  => _feature_type($meta->{source}, 'group', undef, $meta->{is_raft_layer}),
            path_count    => scalar(@children),
            paths         => \@children,
        };
    }

    my $polyline = $entity->polyline;
    my @points = map { [ map unscale($_), @$_ ] } @$polyline;
    my $role_name = _role_name(_safe_call($entity, 'role'));

    return {
        source          => $meta->{source},
        region_id       => $meta->{region_id},
        layer_print_z   => $meta->{layer_print_z},
        type            => 'extrusion_path',
        role_id         => _safe_call($entity, 'role'),
        role_name       => $role_name,
        feature_type    => _feature_type($meta->{source}, $role_name, _safe_call($entity, 'is_bridge'), $meta->{is_raft_layer}),
        is_bridge       => _bool(_safe_call($entity, 'is_bridge')),
        is_solid_infill => _bool(_safe_call($entity, 'is_solid_infill')),
        width           => _safe_num($entity, 'width'),
        height          => _safe_num($entity, 'height'),
        mm3_per_mm      => _safe_num($entity, 'mm3_per_mm'),
        point_count     => scalar(@points),
        points          => \@points,
    };
}

sub _feature_type {
    my ($source, $role_name, $is_bridge, $is_raft_layer) = @_;
    return 'skirt' if defined($source) && $source eq 'skirt';
    return 'brim' if defined($source) && $source eq 'brim';
    return 'support_interface' if defined($source) && $source eq 'support_interface';
    return ($is_raft_layer ? 'raft_support' : 'support') if defined($source) && $source eq 'support';
    return 'bridge' if $is_bridge;

    return 'perimeter_external' if defined($role_name) && $role_name eq 'external_perimeter';
    return 'perimeter_overhang' if defined($role_name) && $role_name eq 'overhang_perimeter';
    return 'perimeter_internal' if defined($role_name) && $role_name eq 'perimeter';
    return 'infill_top_solid' if defined($role_name) && $role_name eq 'top_solid_fill';
    return 'infill_solid' if defined($role_name) && $role_name eq 'solid_fill';
    return 'infill' if defined($role_name) && $role_name eq 'fill';
    return 'gap_fill' if defined($role_name) && $role_name eq 'gap_fill';
    return ($is_raft_layer ? 'raft' : 'infill') if defined($source) && $source eq 'infill';
    return 'unknown';
}

sub _safe_call {
    my ($obj, $method) = @_;
    return undef if !defined($obj) || !blessed($obj) || !$obj->can($method);
    my $v = eval { $obj->$method };
    return $@ ? undef : $v;
}

sub _safe_num {
    my ($obj, $method) = @_;
    my $v = _safe_call($obj, $method);
    return undef if !defined $v;
    return $v + 0;
}

sub _bool {
    my ($v) = @_;
    return undef if !defined $v;
    return $v ? JSON::PP::true : JSON::PP::false;
}

sub _config_to_hash {
    my ($config) = @_;
    my %out = ();
    for my $opt_key (@{$config->get_keys}) {
        my $serialized = eval { $config->serialize($opt_key) };
        next if $@;
        $out{$opt_key} = $serialized;
    }
    return \%out;
}

sub _safe_config_num {
    my ($config, $key) = @_;
    my $v = eval { $config->$key };
    return undef if $@ || !defined $v;
    return $v;
}

sub _role_name {
    my ($role_id) = @_;
    return undef if !defined $role_id;
    my %map = (
        EXTR_ROLE_NONE()                      => 'none',
        EXTR_ROLE_PERIMETER()                 => 'perimeter',
        EXTR_ROLE_EXTERNAL_PERIMETER()        => 'external_perimeter',
        EXTR_ROLE_OVERHANG_PERIMETER()        => 'overhang_perimeter',
        EXTR_ROLE_FILL()                      => 'fill',
        EXTR_ROLE_SOLIDFILL()                 => 'solid_fill',
        EXTR_ROLE_TOPSOLIDFILL()              => 'top_solid_fill',
        EXTR_ROLE_GAPFILL()                   => 'gap_fill',
        EXTR_ROLE_BRIDGE()                    => 'bridge',
        EXTR_ROLE_SKIRT()                     => 'skirt',
        EXTR_ROLE_SUPPORTMATERIAL()           => 'support_material',
        EXTR_ROLE_SUPPORTMATERIAL_INTERFACE() => 'support_material_interface',
    );
    return $map{$role_id};
}

# Export SVG slices for the offline SLA printing.
sub export_svg {
    my $self = shift;
    my %params = @_;
    
    $_->slice for @{$self->objects};
    
    my $fh = $params{output_fh};
    if (!$fh) {
        my $output_file = $self->output_filepath($params{output_file});
        $output_file =~ s/\.gcode$/.svg/i;
        Slic3r::open(\$fh, ">", $output_file) or die "Failed to open $output_file for writing\n";
        print "Exporting to $output_file..." unless $params{quiet};
    }
    
    my $print_bb = $self->bounding_box;
    my $print_size = $print_bb->size;
    print $fh sprintf <<"EOF", unscale($print_size->[X]), unscale($print_size->[Y]);
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.0//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">
<svg width="%s" height="%s" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:slic3r="http://slic3r.org/namespaces/slic3r">
  <!-- 
  Generated using Slic3r $Slic3r::VERSION
  https://slic3r.org/
   -->
EOF
    
    my $print_polygon = sub {
        my ($polygon, $type) = @_;
        printf $fh qq{    <polygon slic3r:type="%s" points="%s" style="fill: %s" />\n},
            $type, (join ' ', map { join ',', map unscale $_, @$_ } @$polygon),
            ($type eq 'contour' ? 'white' : 'black');
    };
    
    my @layers = sort { $a->print_z <=> $b->print_z }
        map { @{$_->layers}, @{$_->support_layers} }
        @{$self->objects};
    
    my $layer_id = -1;
    my @previous_layer_slices = ();
    for my $layer (@layers) {
        $layer_id++;
        if ($layer->slice_z == -1) {
            printf $fh qq{  <g id="layer%d">\n}, $layer_id;
        } else {
            printf $fh qq{  <g id="layer%d" slic3r:z="%s">\n}, $layer_id, unscale($layer->slice_z);
        }
        
        my @current_layer_slices = ();
        # sort slices so that the outermost ones come first
        my @slices = sort { $a->contour->contains_point($b->contour->first_point) ? 0 : 1 } @{$layer->slices};
        foreach my $copy (@{$layer->object->_shifted_copies}) {
            foreach my $slice (@slices) {
                my $expolygon = $slice->clone;
                $expolygon->translate(@$copy);
                $expolygon->translate(-$print_bb->x_min, -$print_bb->y_min);
                $print_polygon->($expolygon->contour, 'contour');
                $print_polygon->($_, 'hole') for @{$expolygon->holes};
                push @current_layer_slices, $expolygon;
            }
        }
        # generate support material
        if ($self->has_support_material && $layer->id > 0) {
            my (@supported_slices, @unsupported_slices) = ();
            foreach my $expolygon (@current_layer_slices) {
                my $intersection = intersection_ex(
                    [ map @$_, @previous_layer_slices ],
                    [ @$expolygon ],
                );
                @$intersection
                    ? push @supported_slices, $expolygon
                    : push @unsupported_slices, $expolygon;
            }
            my @supported_points = map @$_, @$_, @supported_slices;
            foreach my $expolygon (@unsupported_slices) {
                # look for the nearest point to this island among all
                # supported points
                my $contour = $expolygon->contour;
                my $support_point = $contour->first_point->nearest_point(\@supported_points)
                    or next;
                my $anchor_point = $support_point->nearest_point([ @$contour ]);
                printf $fh qq{    <line x1="%s" y1="%s" x2="%s" y2="%s" style="stroke-width: 2; stroke: white" />\n},
                    map @$_, $support_point, $anchor_point;
            }
        }
        print $fh qq{  </g>\n};
        @previous_layer_slices = @current_layer_slices;
    }
    
    print $fh "</svg>\n";
    close $fh;
    print "Done.\n" unless $params{quiet};
}

sub make_brim {
    my $self = shift;
    
    # prerequisites
    $_->make_perimeters for @{$self->objects};
    $_->infill for @{$self->objects};
    $_->generate_support_material for @{$self->objects};
    $self->make_skirt;
    
    $self->status_cb->(88, "Generating brim");
    $self->_make_brim;
}

# Wrapper around the C++ Slic3r::Print::validate()
# to produce a Perl exception without a hang-up on some Strawberry perls.
sub validate
{
    my $self = shift;
    my $err = $self->_validate;
    die $err . "\n" if (defined($err) && $err ne '');
}

1;
