#!/usr/bin/perl
#
# Copyright (C) 2013-2014   Ian Firns   <firnsy@kororaproject.org>
#                           Chris Smart <csmart@kororaproject.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
package Canvas;

use warnings;
use strict;

use Mojo::Base 'Mojolicious';

#
# PERL INCLUDES
#
use Data::Dumper;

use Mojo::ByteStream;
use Mojo::JSON;
use Mojolicious::Plugin::Authentication;
use Mojolicious::Plugin::Cache;
use Mojolicious::Plugin::JSONConfig;
use Mojolicious::Plugin::Mail;

use POSIX qw(floor);
use Time::Piece;

#
# LOCAL INCLUDES
#
use Canvas::About;
use Canvas::Helpers;
use Canvas::Helpers::Engage;
use Canvas::Site;
use Canvas::Store::User;
use Canvas::Util::PayPal::API;
use Canvas::Util::PayPal::Payment;

#
# CONSTANTS
#
use constant {
  DEBUG   => 1
};


#
# INITIALISE
#
sub startup {
  my $self = shift;

  $self->secret('canvas');

  #
  # CONFIGURATION
  my $config = $self->plugin('JSONConfig' => {
    file => './canvas.conf',
  });

  #
  # HYPNOTOAD
  $self->app->config(hypnotoad => $config->{hypnotoad} // {} );

  #
  # CACHE
  $self->plugin('Cache' => $config->{cache} // {} );

  # set default session expiration to 4 hours
  $self->sessions->default_expiration(14400);

  #
  # AUTHENTICATION
  $self->app->log->info('Loading authentication handler.');
  $self->plugin('authentication' => {
    autoload_user   => 0,
    current_user_fn => 'auth_user',
    load_user       => sub {
      my( $app, $uid ) = @_;

      return Canvas::Store::User->search( username => $uid )->first;
    },
    validate_user   => sub {
      my( $app, $user, $pass, $extra ) = @_;

      my $u = Canvas::Store::User->search( username => $user )->first;

      if( defined($u) && $u->status eq 'active' && $u->validate_password($pass)  ) {
        return $u->username;
      };

      return undef;
    },
  });

  #
  # MAIL
  unless( $config->{mail} && ( $config->{mail}{mode} // '') eq 'production' ) {
    $self->app->log->info('Loading dummy mail handler for non-production testing.');

    $self->helper('mail' => sub {
      shift->app->log->debug('Sending an email ' . join "\n", @_);
    });
  }
  else {
    $self->app->log->info('Loading production mail handler.');
    $self->plugin('mail' => {
      type => 'text/plain',
    });
  }

  #
  # HELPERS
  $self->app->log->info('Loading page helpers.');
  $self->plugin('Canvas::Helpers');
  $self->plugin('Canvas::Helpers::Documentation');
  $self->plugin('Canvas::Helpers::Engage');
  $self->plugin('Canvas::Helpers::News');
  $self->plugin('Canvas::Helpers::Profile');

  #
  # PAYPAL

  # prepare the PayPal transaction information
  my $pp_context = Canvas::Util::PayPal::API->new(
    client_id     => $config->{paypal}{client_id},
    client_secret => $config->{paypal}{client_secret},
  );

  $self->cache->set(pp_context => $pp_context);

  #
  # ROUTES
  my $r = $self->routes;

  $r->get('/')->to('site#index');

  #
  # exception/not_found
  $r->get('/404')->to('site#not_found_get');
  $r->get('/500')->to('site#exception_get');

  # about pages
  $r->get('/about')->to('about#index');
  $r->get('/about/roadmap')->to('about#roadmap');
  $r->get('/about/team')->to('about#team');
  $r->get('/about/whats-inside')->to('about#whats_inside');
  $r->get('/about/why-fedora')->to('about#why_fedora');

  # about-news pages
  $r->get('/about/news')->to('news#index');
  $r->post('/about/news')->to('news#news_post');
  $r->get('/about/news/admin')->to('news#news_admin_get');
  $r->get('/about/news/add')->to('news#news_add_get');
  $r->get('/about/news/rss')->to('news#rss_get');
  $r->get('/about/news/:id')->to('news#news_post_get');
  $r->get('/about/news/:id/edit')->to('news#news_post_edit_get');
  $r->any('/about/news/:id/delete')->to('news#news_post_delete_any');

  # discover pages
  $r->get('/discover')->to('discover#index');
  $r->get('/discover/gnome')->to('discover#gnome');
  $r->get('/discover/kde')->to('discover#kde');
  $r->get('/discover/cinnamon')->to('discover#cinnamon');
  $r->get('/discover/mate')->to('discover#mate');
  $r->get('/discover/xfce')->to('discover#xfce');

  # support pages
  $r->get('/support')->to('support#index_get');
  $r->get('/support/documentation')->to('documentation#index_get');
  $r->post('/support/documentation')->to('documentation#document_add_post');
  $r->get('/support/documentation/admin')->to('documentation#document_admin_get');
  $r->get('/support/documentation/add')->to('documentation#document_add_get');
  $r->get('/support/documentation/:id')->to('documentation#document_detail_get');
  $r->get('/support/documentation/:id/edit')->to('documentation#document_edit_get');
  $r->post('/support/documentation/:id/edit')->to('documentation#document_edit_post');
  $r->any('/support/documentation/:id/delete')->to('documentation#document_delete_any');


  $r->get('/support/engage')->to('engage#index');
  $r->get('/support/engage/syntax')->to('engage#engage_syntax_get');
  $r->get('/support/engage/:type')->to('engage#engage_summary');
  $r->get('/support/engage/:type/add')->to('engage#engage_post_prepare_add_get');
  $r->post('/support/engage/:type/add')->to('engage#engage_post_add_post');
  $r->get('/support/engage/:type/:stub')->to('engage#engage_post_detail_get');
  $r->get('/support/engage/:type/:stub/edit')->to('engage#engage_post_edit_get');
  $r->post('/support/engage/:type/:stub/edit')->to('engage#engage_post_edit_post');
  $r->any('/support/engage/:type/:stub/delete')->to('engage#engage_post_delete_any');
  $r->any('/support/engage/:type/:stub/subscribe')->to('engage#engage_post_subscribe_any');
  $r->any('/support/engage/:type/:stub/unsubscribe')->to('engage#engage_post_unsubscribe_any');
  $r->post('/support/engage/:type/:stub/reply')->to('engage#engage_reply_post');
  $r->any('/support/engage/:type/:stub/reply/:id')->to('engage#engage_reply_any');
  $r->get('/support/engage/:type/:stub/reply/:id/edit')->to('engage#engage_reply_edit_get');
  $r->post('/support/engage/:type/:stub/reply/:id/edit')->to('engage#engage_reply_edit_post');
  $r->any('/support/engage/:type/:stub/reply/:id/accept')->to('engage#engage_reply_accept_any');
  $r->any('/support/engage/:type/:stub/reply/:id/delete')->to('engage#engage_reply_delete_any');
  $r->any('/support/engage/:type/:stub/reply/:id/unaccept')->to('engage#engage_reply_unaccept_any');


  # contribute pages
  $r->get('/contribute')->to('contribute#index_get');
  $r->get('/contribute/donate')->to('contribute#donate_get');
  $r->post('/contribute/donate')->to('contribute#donate_post');
#  $r->get('/contribute/sponsor')->to('contribute#sponsor_get');
#  $r->post('/contribute/sponsor')->to('contribute#sponsor_post');

  # download pages
  $r->get('/download')->to('download#index');



  # authentication and registration
  $r->any('/authenticate')->to('site#authenticate_any');
  $r->any('/deauthenticate')->to('site#deauthenticate_any');
  $r->get('/register')->to('site#register_get');
  $r->post('/register')->to('site#register_post');
  $r->get('/registered')->to('site#registered_get');
  $r->get('/activate/:username')->to('site#activate_get');
  $r->post('/activate/:username')->to('site#activate_post');
  $r->get('/activated')->to('site#activated');
  $r->post('/forgot')->to('site#forgot_post');


  # profile pages
  $r->get('/profile/admin')->to('profile#profile_admin_get');
  $r->post('/profile/status')->to('profile#profile_status_post');
  $r->get('/profile/:name')->to('profile#profile_get');
  $r->get('/profile/:name/reset')->to('profile#profile_reset_password_get');
  $r->post('/profile/:name/reset')->to('profile#profile_reset_password_post');


  # archive.* captures
  $r->get('/help/forums')->to('site#forums_get');
  $r->any('/20*archive')->to('site#archive_forward_any');
  $r->any('/category*archive')->to('site#archive_forward_any');
  $r->any('/forum*archive')->to('site#archive_forward_any');
  $r->any('/topic*archive')->to('site#archive_forward_any');
  $r->any('/wp-*archive')->to('site#archive_forward_any');


  #
  # CANVAS API ROUTES
  my $r_api = $r->under('/api');

  $r_api->get('/packages')->to('core#packages_get');
  $r_api->get('/packages/latest')->to('core#packages_latest_get');
  $r_api->get('/package/:id')->to('core#package_id_get');
  $r_api->put('/package/:id')->to('core#package_id_put');
  $r_api->delete('/package/:id')->to('core#package_id_del');

  $r_api->get('/users')->to('core#users_get');
  $r_api->get('/user/:id')->to('core#user_id_get');
  $r_api->get('/user/:id/memberships')->to('core#user_id_memberships_get');

  $r_api->get('/repositories')->to('core#repositories_get');
  $r_api->post('/repositories')->to('core#repositories_post');
  $r_api->get('/repository/:id')->to('core#repository_id_get');

  $r_api->get('/templates')->to('core#templates_get');
  $r_api->post('/templates')->to('core#templates_post');
  $r_api->get('/template/:id')->to('core#template_id_get');
  $r_api->put('/template/:id')->to('core#template_id_put');
  $r_api->delete('/template/:id')->to('core#template_id_del');

  $r_api->get('/user/:user/template/:name')->to('core#user_user_template_name_get');
  $r_api->put('/user/:user/template/:name')->to('core#user_user_template_name_put');
  $r_api->delete('/user/:user/template/:name')->to('core#user_user_template_name_del');
}

1;
