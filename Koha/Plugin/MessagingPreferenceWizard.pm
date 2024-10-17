package Koha::Plugin::MessagingPreferenceWizard;
# Bouzid Fergani, 2016 - InLibro
#
# This plugin allows you to generate a Carrousel of books from available lists
# and insert the template into the table system preferences;OpacMainUserBlock
#
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Members;
use C4::Auth;
use C4::Members::Messaging;
use C4::Context;
use Pod::Usage;
use Getopt::Long;
use Data::Dumper;
use File::Spec;
use Koha::DateUtils qw ( dt_from_string );

our $VERSION = 1.6;

our $metadata = {
    name   => 'Enhanced messaging preferences wizard',
    author => 'Bouzid Fergani, Alexandre Noël, Olivier Vezina',
    description => 'Setup or reset the enhanced messaging preferences to default values',
    date_authored   => '2016-07-13',
    date_updated    => '2024-10-17',
    minimum_version => '22.05.00',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);
    return $self;
}


sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $op = $cgi->param('op') || '';
    my $kohaversion = Koha::version;
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;
    my @sortie = `ps -eo user,bsdstart,command --sort bsdstart`;
    my @lockfile = `ls -s /tmp/.PluginMessaging.lock 2>/dev/null`;
    my @process;
    foreach my $val (@sortie){
        push @process, $val if ($val =~ '/plugins/run.pl');
    }
    my $nombre = scalar (@process);
    my $lock = scalar (@lockfile);
    my $truncate = $cgi->param('trunc');
    my $since = $cgi->param('since');
    my $category = $cgi->param('category');
    my $library = $cgi->param('library');
    my $message_name = $cgi->param('message-name');
    my $exclude_expired = $cgi->param('exclude-expired');
    my $no_overwrite = $cgi->param('no-overwrite');
    
    if ($op eq 'valide'){
        if ($since) {
            $since = eval { dt_from_string(scalar $since) };
        }
        warn "[Koha::Plugin::MessagingPreferenceWizard::tool][DEBUG] Truncate is ON, DELETE'ing borrower_message_preferences\n"
            if $truncate;
        warn "[Koha::Plugin::MessagingPreferenceWizard::tool][DEBUG] Only updating accounts where dateenrolled >= $since\n";
        my $dbh = C4::Context->dbh;
        #$dbh->{AutoCommit} = 0;
        if ( $truncate ) {
            my $sth = $dbh->prepare("DELETE FROM borrower_message_preferences");
            $sth->execute();
        }

        my $sql = 
q|SELECT DISTINCT bo.borrowernumber, bo.categorycode FROM borrowers bo
LEFT JOIN borrower_message_preferences mp USING (borrowernumber)
WHERE 1|;
        my $script_path = '/usr/share/koha/bin/maintenance/borrowers-force-messaging-defaults.pl';
        if(C4::Context->config("dev_install")){
            $script_path = '../misc/maintenance/borrowers-force-messaging-defaults.pl';
        }
        my $command = "perl $script_path --doit";
        if ( $since ) {
            $command .= " --since $since";
            $sql .= " AND bo.dateenrolled >= ?";
        }
        if ( $category ) {
            $command .= " --category $category";
            $sql .= " AND bo.categorycode = ?";
        }
        if ( $library ) {
            $command .= " --library $library";
            $sql .= " AND bo.branchcode = ?";
        }
        if ( $exclude_expired ) {
            $command .= " --exclude-expired";
            $sql .= " AND bo.dateexpiry >= NOW()";
        }
        if ( $no_overwrite ) {
            $command .= " --no-overwrite";
            $sql .= " AND mp.borrowernumber IS NULL";
        }
        $command .= " --message-name $message_name" if $message_name;

        my $sth = $dbh->prepare($sql);
        $sth->execute($since || (), $category || (), $library || () );
        my $result = $sth->fetchall_arrayref();
        my $number = scalar @$result;
        my $pid = fork();
        if ( $pid ){
            my $preferedLanguage = $cgi->cookie('KohaOpacLanguage') || '';
            my $template = undef;
            eval {$template = $self->get_template( { file => "messaging_preference_wizard_$preferedLanguage.tt" } )};
            if(!$template && $preferedLanguage){
                $preferedLanguage = substr $preferedLanguage, 0, 2;
                eval {$template = $self->get_template( { file => "messaging_preference_wizard_$preferedLanguage.tt" } )};
            }
            $template = $self->get_template( { file => 'messaging_preference_wizard.tt' } ) unless $template;
            $template->param('attente' => 1);
            $template->param( exist => 0);
            $template->param( lock => 0);
            $template->param(decompte => $number);
            $template->param(version => $kohaversion);
            print $cgi->header(-type => 'text/html',-charset => 'utf-8');
            print $template->output();
            exit 0;
        }else{
            close STDOUT;
        }
        open  my $fh,">",File::Spec->catdir("/tmp/",".PluginMessaging.lock");
        warn "[Koha::Plugin::MessagingPreferenceWizard::tool][DEBUG] $command\n";
        my $output = `$command`;
        warn "[Koha::Plugin::MessagingPreferenceWizard::tool][DEBUG] $output\n";
        `rm /tmp/.PluginMessaging.lock 2>/dev/null`;
        exit 0;
    }else{
        $self->show_config_pages($nombre,$lock);
    }
}

# CRUD handler - Displays the UI for listing of existing pages.
sub show_config_pages {
    my ( $self, $nombre, $lock) = @_;
    my $cgi = $self->{'cgi'};
    my $kohaversion = Koha::version;
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;
    my $preferedLanguage = $cgi->cookie('KohaOpacLanguage') || '';
    my $template = undef;
    eval {$template = $self->get_template( { file => "messaging_preference_wizard_$preferedLanguage.tt" } )};
    if(!$template){
        $preferedLanguage = substr $preferedLanguage, 0, 2;
        eval {$template = $self->get_template( { file => "messaging_preference_wizard_$preferedLanguage.tt" } )};
    }
    $template = $self->get_template( { file => 'messaging_preference_wizard.tt' } ) unless $template;
    $template->param('attente' => 0);
    $template->param( exist => $nombre);
    $template->param( lock => $lock);
    $template->param( number => 0);
    $template->param( decompte => 0);
    $template->param( version => $kohaversion);

    my $categories = Koha::Patron::Categories->search();
    $template->param(categories => $categories);
    warn "kohaversion = $kohaversion\n";
    if ( $kohaversion >= 23.11 ) {
        my $libraries = Koha::Libraries->search();
        my @message_names = Koha::Patron::MessagePreference::Attributes->search()->get_column('message_name');
        $template->param(
            libraries => $libraries,
            message_names => \@message_names,
        );
    }

    print $cgi->header(-type => 'text/html',-charset => 'utf-8');
    print $template->output();
}

# Generic uninstall routine - removes the plugin from plugin pages listing
sub uninstall() {
    my ( $self, $args ) = @_;
}
1;
