<?php
/**
 * Custom Adminer entry point.
 *
 * - Restricts the available database drivers to PostgreSQL only.
 * - Sets a custom application name (browser tab + headings).
 *
 * This file replaces the default /var/www/html/index.php shipped with the
 * adminer:latest Docker image. It is mounted via a Docker Swarm config.
 */

namespace Adminer;

function adminer_object()
{
    class AdminerPostgresOnly extends Adminer
    {
        public function name()
        {
            return 'PostgreSQL Cluster Admin';
        }

        public function loginForm()
        {
            // Restrict the driver dropdown to PostgreSQL only.
            global $drivers;
            $drivers = ["pgsql" => "PostgreSQL"];
            parent::loginForm();
        }

        public function head($dark = null)
        {
            parent::head($dark);
            // Layer custom overrides on top of the active design's adminer.css.
            // Mounted separately to avoid clashing with the entrypoint's
            // `ln -s designs/<ADMINER_DESIGN>/adminer.css adminer.css`.
            echo '<link rel="stylesheet" type="text/css" href="adminer-custom.css">' . "\n";
        }
    }

    return new AdminerPostgresOnly();
}

include './adminer.php';
