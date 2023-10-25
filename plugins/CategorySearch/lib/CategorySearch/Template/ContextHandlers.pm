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

package CategorySearch::Template::ContextHandlers;

use strict;

sub _hdlr_category_search_link {
	my($ctx, $args, $cond) = @_;
	my $blog_id = $ctx->stash('blog_id');
	if (! $blog_id) {
		my $blog = $ctx->stash('blog');
		$blog_id = $blog->id;
	}
	$blog_id ||= '';

	require MT;
	my $app = MT->instance;

	my $value = $args->{value};
	if ($value =~ m/^\$(.+)/) {
		$value = $ctx->var($1);
	}

	my $set = $args->{set};
	if ($set =~ m/^\$(.+)/) {
		$set = $ctx->var($1);
	}

	my $op = $args->{op} || 'replace';
	my $type = $args->{type} || 'relative';
	my $text_search = $args->{text} || 'ignore';
	my @include_blogs = split(/,/, ($args->{IncludeBlogs} || $blog_id));

	my $limit = $args->{limit} || 20;
	my @csets = ();

	if ($app->can('param')) {
		$limit = $app->param('limit') || $limit;
		@csets = $app->param('CategorySearchSets');
	}

	if ((! @csets) || ($type eq 'absolute')) {
		@csets = ($set);
	}
	else {
		if (! grep({ $_ eq $set } @csets)) {
			push(@csets, $set);
		}
	}

	my $q = new CGI('');
	my @ignore_params = ('startIndex', 'limit', 'offset', 'format');
	if ($text_search eq 'ignore') {
		push(@ignore_params, 'searchTerms', 'search');
	}
	if ($app->isa('MT::App::Search')) {
		foreach my $p ($app->param) {
			if (! grep({ $_ eq $p } @ignore_params)) {
				$q->param($p, $app->param($p));
			}
		}
	}
	$q->param('CategorySearchSets', @csets);
	$q->param('CategorySearch', 1);
	$q->param('CategorySearchIgnoreText', $text_search eq 'ignore');
	if (@include_blogs) {
		$q->param('IncludeBlogs', join(',', @include_blogs));
	}
	$q->param('limit', $limit);

	my $same_query = 1;
	my @cats0 = ();
	foreach my $cs (@csets) {
		my @queries = ();
		if ($app->can('param')) {
			@queries = grep({ $_ } map({
				my $str = $_;
				$str =~ s/^\s*(.*?)\s*$/$1/;
				$str;
			} $app->param($cs)));
		}

		if ($cs eq $set) {
			if ($op eq 'replace') {
				@queries = ($value);
			}
			elsif ($op eq 'clear') {
				@queries = ();
			}
			elsif ($op eq 'add') {
				if (! grep({ $_ eq $value } @queries)) {
					push(@queries, $value);
				}
			}
			elsif ($op eq 'remove') {
				@queries = grep({ $_ ne $value } @queries);
			}
		}

		{
			my @qs = $q->param($cs);
			if (scalar(@qs) != scalar(@queries)) {
				$same_query = 0;
			}
			else {
				for (my $i = 0; $i < scalar(@qs); $i++) {
					if ($qs[$i] ne $queries[$i]) {
						$same_query = 0;
					}
				}
			}
		}
		
		if (! @queries) {
			$q->delete($cs);
			next;
		}
		else {
			if (utf8::is_utf8($queries[0])) {
				$q->param($cs, map(Encode::encode('utf-8', $_), @queries));
			}
			else {
				$q->param($cs, @queries);
			}
		}

		my $type = 'or';
		if ($app->can('param') && $app->param($cs . '_type')) {
			$type = lc($app->param($cs . '_type'));
		}

		my @cats1 = ();
		foreach my $query (@queries) {
			push(@cats1,
				(scalar(@cats1) ? ('-' . $type) : ()),
				{ 'label' => $query }
			);
		}

		push(@cats0,
			(scalar(@cats0) ? '-or' : ()),
			\@cats1
		);
	}

	require MT::Entry;

	my $terms = @cats0 ? [\@cats0] : [];

	if ( exists $app->{searchparam}{IncludeBlogs} ) {
		unshift(@$terms, '-and');
		if (ref $app->{searchparam}{IncludeBlogs} eq 'HASH') {
			unshift(@$terms, {
				'blog_id' => [ keys %{ $app->{searchparam}{IncludeBlogs} } ],
			});
		}
		else {
			unshift(@$terms, {
				'blog_id' => $app->{searchparam}{IncludeBlogs},
			});
		}
	}
	elsif ((! $app->isa('MT::App::Search')) && @include_blogs) {
		unshift(@$terms, '-and');
		unshift(@$terms, { 'blog_id' => \@include_blogs });
	}

	push(@$terms, '-and', {
		id      => \'= placement_category_id',
		blog_id => \'= entry_blog_id',
	});

	require MT::Placement;
	require MT::Category;
	my $join_on = MT::Placement->join_on(
		undef,
		{ entry_id => \'= entry_id', blog_id => \'= entry_blog_id' },
		{
			join   => MT::Category->join_on( undef, $terms, {} ),
			unique => 1
		}
	);

	my $count_ge = int((scalar(@cats0) + 1) / 2);
	my $counter = MT::Entry->driver->_do_group_by(
		' entry_id ',
		'MT::Entry',
		undef,
		{
			'join' => $join_on,
			'group' => [ 'id' ],
			'having' => {
				'COUNT(*)' => \('>= ' . $count_ge),
			},
		}
	);

	my $count = 0;
	while ($counter->()) {
		$count++;
	}

	my $builder = $ctx->stash('builder');
	my $tokens = $ctx->stash('tokens');
	my $glue = exists $args->{glue} ? $args->{glue} : '';
	my $vars = $ctx->{__stash}{vars} ||= {};

	local $vars->{count} = $count;
	local $vars->{selected} = $same_query;
	local $vars->{searching} = $app->isa('MT::App::Search');

	local $CGI::USE_PARAM_SEMICOLONS;
	$CGI::USE_PARAM_SEMICOLONS = 0;
	#local $vars->{url} = $q->self_url;
	my $path = ($ctx->handler_for('CGIPath'))[0]->($ctx, $args);
	local $vars->{url} =
		$path . $ctx->{config}->SearchScript . '?' . $q->query_string;

	defined(my $out = $builder->build($ctx, $tokens,
			{ %$cond },
	)) or return $ctx->error( $builder->errstr );

	$out;
}

sub _hdlr_category_search_sets {
	my($ctx, $args, $cond) = @_;

	require MT;
	my $app = MT->instance;

	my @csets = $app->param('CategorySearchSets');

	my $res = '';
	my $builder = $ctx->stash('builder');
	my $tokens = $ctx->stash('tokens');
	my $glue = exists $args->{glue} ? $args->{glue} : '';
	my $vars = $ctx->{__stash}{vars} ||= {};

	local $ctx->{__stash}{'category_search_sets_header'};
	local $ctx->{__stash}{'category_search_sets_footer'};

	@csets = grep({
		my $cs = $_;
		grep({ $_ } map({
			my $str = $_;
			$str =~ s/^\s*(.*?)\s*$/$1/;
			$str;
		} $app->param($cs)));
	} @csets);

	
	for (my $i = 0; $i < scalar(@csets); $i++) {
		my $cs = $csets[$i];
		local $ctx->{__stash}{category};
		if ($cs =~ m/^\d+$/) {
			my $cat = MT::Category->load($cs);
			if ($cat) {
				$ctx->{__stash}{category} = $cat;
			}
		}
		local $ctx->{__stash}{CategorySearchSet} = $cs;

		$ctx->{__stash}{'category_search_sets_header'} = ($i == 0);
		$ctx->{__stash}{'category_search_sets_footer'} = ($i == $#csets);

		local $vars->{set} = $cs;

		defined(my $out = $builder->build($ctx, $tokens, $cond))
			or return $ctx->error( $builder->errstr );
		$res .= $glue if $res ne '';
		$res .= $out;
	}
	$res;
}

sub _hdlr_category_search_sets_header {
	&get_contents('category_search_sets_header', @_);
}

sub _hdlr_category_search_sets_footer {
	&get_contents('category_search_sets_footer', @_);
}

sub _hdlr_category_search_categories {
	my($ctx, $args, $cond) = @_;

	require MT;
	my $app = MT->instance;

	my @csets = ();
	if (my $set = $ctx->stash('CategorySearchSet')) {
		@csets = ($set);
	}
	else {
		@csets = $app->param('CategorySearchSets');
	}

	my $res = '';
	my $builder = $ctx->stash('builder');
	my $tokens = $ctx->stash('tokens');
	my $glue = exists $args->{glue} ? $args->{glue} : '';
	my $vars = $ctx->{__stash}{vars} ||= {};

	local $ctx->{__stash}{'category_search_categories_header'};
	local $ctx->{__stash}{'category_search_categories_footer'};

	for (my $i = 0; $i < scalar(@csets); $i++) {
		my $cs = $csets[$i];
		my @queries = grep({ $_ } map({
			my $str = $_;
			$str =~ s/^\s*(.*?)\s*$/$1/;
			$str;
		} $app->param($cs)));

		for (my $j = 0; $j < scalar(@queries); $j++) {
			my $q = $queries[$j];
			local $ctx->{__stash}{category};
			my $cat = MT::Category->load({ label => $q })
				or next;
			$ctx->{__stash}{category} = $cat;

			$ctx->{__stash}{'category_search_categories_header'} =
				(($i == 0) && ($j == 0));
			$ctx->{__stash}{'category_search_categories_footer'} =
				(($i == $#csets) && ($j == $#queries));

			local $vars->{category_label} = $q;

			defined(my $out = $builder->build($ctx, $tokens, $cond))
				or return $ctx->error( $builder->errstr );
			$res .= $glue if $res ne '';
			$res .= $out;
		}
	}

	$res;
}

sub get_contents {
	my ($key, $ctx, $args, $cond) = @_;

	if (! $ctx->stash($key)) {
		return '';
	}

	my $builder = $ctx->stash('builder');
	my $tokens = $ctx->stash('tokens');

	defined(my $str = $builder->build($ctx, $tokens, $cond))
		or return $ctx->error( $builder->errstr );

	$str;
}

sub _hdlr_category_search_categories_header {
	&get_contents('category_search_categories_header', @_);
}

sub _hdlr_category_search_categories_footer {
	&get_contents('category_search_categories_footer', @_);
}

sub _hdlr_if_category_search {
	my($ctx, $args, $cond) = @_;

	require MT;
	my $app = MT->instance;
	my $enable = $app->can('param') && $app->param('CategorySearch');

	if ($ctx->this_tag() =~ m/unless/i) {
		not $enable;
	}
	else {
		$enable;
	}
}

1;
