#   Copyright (c) 2008 ToI-Planning, All rights reserved.
# 
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions
#   are met:
# 
#   1. Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#
#   2. Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#
#   3. Neither the name of the authors nor the names of its contributors
#      may be used to endorse or promote products derived from this
#      software without specific prior written permission.
#
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
#   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
#   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
#   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
#   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
#  $Id$

package CategorySearch::App;

use strict;
use warnings;

sub enabled {
    my ($app) = @_;
    $app ||= MT->instance;
    $app->can('param') && $app->param('CategorySearch');
}

sub init_app {
    my ( $cb, $app ) = @_;

    require MT::App::Search;

    local $SIG{__WARN__} = sub { };
    if ( $MT::VERSION < 4.2 ) {
        my $hit_method = \&MT::App::Search::_search_hit;
        *MT::App::Search::_search_hit = sub {
            enabled($app)
                ? &_search_hit( $hit_method, @_ )
                : $hit_method->(@_);
        };
    }
    else {
        my $search_terms = \&MT::App::Search::search_terms;
        *MT::App::Search::search_terms = sub {
            enabled($app)
                ? &search_terms( $search_terms, @_ )
                : $search_terms->(@_);
        };

        my $_log_search = \&MT::App::Search::_log_search;
        *MT::App::Search::_log_search = sub {
            enabled($app) ? () : $_log_search->(@_);
        };

        require MT::Template::Context::Search;
        my $context_script = \&MT::Template::Context::Search::context_script;
        *MT::Template::Context::Search::context_script = sub {
            enabled($app)
                ? context_script(@_)
                : $context_script->(@_);
        };
    }
}

sub init_request {
    my ( $plugin, $app ) = @_;

    if ( $app->isa('MT::App::Search') && enabled($app) ) {
        if ( $MT::VERSION >= 4.2 ) {
            if ( $app->param('CategorySearchIgnoreText') ) {
                $app->param( 'search', 'abc' );
            }
        }
    }
}

sub context_script {
	my ( $ctx, $args, $cond ) = @_;

	require MT;
	my $app = MT->instance;

	my $cgipath = ($ctx->handler_for('CGIPath'))[0]->($ctx, $args);
	my $script = $ctx->{config}->SearchScript;

	my @ignores = ('startIndex', 'limit', 'offset', 'format', 'page');
	my $q = new CGI('');
	if ($app->isa('MT::App::Search')) {
		foreach my $p ($app->param) {
			if (! grep({ $_ eq $p } @ignores)) {
				$q->param($p, $app->param($p));
			}
		}
	}

	local $CGI::USE_PARAM_SEMICOLONS;
	$CGI::USE_PARAM_SEMICOLONS = 0;
	$cgipath . $script . '?' . $q->query_string;
}

sub search_terms {
	my $search_terms = shift;
	my ($app) = @_;
	my ($terms, $args) = $search_terms->(@_);

	my $combination_type =
		lc($app->param('CategorySearchCombinationType') || 'and');

	my @csets = $app->multi_param('CategorySearchSets');
	my @cats0 = ();
	my $only_single_queies = 1;

    require MT::Category;
    require MT::Placement;

    my $categories = do {
        my @labels = map({
            my $cs = $_;
		    grep({ $_ } map({
			    my $str = $_;
			    $str =~ s/^\s*(.*?)\s*$/$1/;
			    $str;
		    } $app->multi_param($cs)));
        } @csets);

        my %hash = ();
        my @cats = MT::Category->load(
            { label => \@labels },
            { fetch_only => ['id', 'label'] }
        );
        foreach my $c (@cats) {
            $hash{$c->label} = $c->id;
        }

        \%hash;
    };

	foreach my $cs (@csets) {
		my @queries = grep({ $_ } map({
			my $str = $_;
			$str =~ s/^\s*(.*?)\s*$/$1/;
			$str;
		} $app->multi_param($cs)));
		if (! @queries) {
			next;
		}

		$only_single_queies = 0 if scalar(@queries) > 1;

		my @cats1 = ();
		foreach my $query (@queries) {
			push(@cats1, $categories->{$query});
		}

		my $type = lc($app->param($cs . '_type') || 'or');
		push(@cats0, [$type, \@cats1]);
	}


	my %ids = ();
	my @ids = ();

	if (scalar(@cats0) > 1 && $only_single_queies) {
		my @replace = ();
		foreach my $cat (@cats0) {
			push(@replace, @{ $cat->[1] });
		}
		@cats0 = ([$combination_type, \@replace]);
	}

    foreach my $cat (@cats0) {
        my ( $type, $terms ) = @$cat;

        my $count_ge = $type eq 'or' ? 1 : scalar(@$terms);
        my $iter = MT::Placement->count_group_by(
            { category_id => $terms },
            {
                group  => ['entry_id'],
                having => { 'COUNT(*)' => \( '>= ' . $count_ge ), },
            }
        );

        while ( my ( $count, $id ) = $iter->() ) {
            $ids{$id}++;
        }
    }

	if (%ids) {
		my $count_ge = $combination_type eq 'or' ? 1 : scalar @cats0;
		while (my ($id, $count) = each %ids) {
			push @ids, $id if $count >= $count_ge;
		}
	}

	my $where = undef;
	for (my $i = scalar(@$terms); $i >= 0; $i--) {
		if ((ref $terms->[$i]) eq 'ARRAY') {
			$where = $terms->[$i];
		}
	}

	if (
		! $app->param('CustomFieldsSearch') &&
		$app->param('CategorySearchIgnoreText')
	) {
		$app->{search_string} = '';
		while (@$where) {
			shift(@$where);
		}
	}

    if (@cats0) {
	    push(@$where, (scalar(@$where) ? '-and' : ()), {
		    'id' => (@ids ? \@ids : \' IS NULL'),
	    });
    }
    else {
	    push(@$where, (scalar(@$where) ? '-and' : ()), {
		    'id' => \' IS NOT NULL',
	    });
    }

	($terms, $args);
}

sub _search_hit {
	my ($hit_method, $app, $entry) = @_;

	if (! $app->param('CategorySearchIgnoreText')) {
		return 0 unless &{$hit_method}($app, $entry);
	}
	return 0 if $app->{searchparam}{SearchElement} ne 'entries';

	my @status0 = 0;
	my $cats = $entry->categories;
	my @csets = $app->param('CategorySearchSets');
	foreach my $cs (@csets) {
		my @status1 = ();
		my @queries = grep({ $_ } map({
			my $str = $_;
			$str =~ s/^\s*(.*?)\s*$/$1/;
			$str;
		} $app->param($cs)));
		if (! @queries) {
			push(@status0, 1);
		}
		else {
			foreach my $query (@queries) {
				my $stat = 0;
				foreach my $c (@$cats) {
					if ($c->label eq $query) {
						$stat = 1;
						last;
					}
				}
				push(@status1, $stat);
			}
			my $type = lc($app->param($cs . '_type') || 'or');
			if ($type eq 'and') {
				push(@status0, ! scalar(grep({ ! $_ } @status1)));
			}
			else {
				push(@status0, scalar(grep({ $_ } @status1)));
			}
		}
	}

	return (! scalar(grep({ ! $_ } @status0)));
}

1;
